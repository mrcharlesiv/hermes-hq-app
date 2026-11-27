using System.Text.RegularExpressions;
using Hermes.Core.Settings;

namespace Hermes.Core.Tests;

/// [density] [top-edge] Settings › Appearance › Bots & Sessions › Density and App › Top Edge (Mac 93f984bb1
/// HermesKit/Theme/ThemeState.swift `ListDensity`, `TopEdge`, ThemeStore keys; App/Settings/Appearance/AppearancePage.swift
/// `DensityRow`, `TopEdgeRow`, `lists`, `app`, `compactNote`; App/Theme/TopEdgeStyle.swift `offered`; App/Mac/SidebarType.swift
/// `current`; App/Sessions/SessionRowViews.swift `macTight`). Synthetic preferences only.
public class DensityTopEdgeTests
{
    // ---------------------------------------------------------------- saved choices

    [Fact]
    public void TheMacsKeysRawValuesAndDefaults()
    {
        Assert.Equal("hqn.theme.density", ThemeStore.Key.Density);
        Assert.Equal("hqn.theme.topEdge", ThemeStore.Key.TopEdge);
        Assert.Contains(ThemeStore.Key.Density, ThemeStore.Key.All);
        Assert.Contains(ThemeStore.Key.TopEdge, ThemeStore.Key.All);
        Assert.Equal("standard", ListDensity.Standard.Raw());
        Assert.Equal("compact", ListDensity.Compact.Raw());
        Assert.Equal("soft", TopEdge.Soft.Raw());
        Assert.Equal("hard", TopEdge.Hard.Raw());
        Assert.Equal(ListDensity.Standard, ThemeState.Default.Density);
        Assert.Equal(TopEdge.Hard, ThemeState.Default.TopEdge);   // Hard since build 734
        var empty = new ThemeStore(new MemoryPrefs()).Load();
        Assert.Equal(ListDensity.Standard, empty.Density);
        Assert.Equal(TopEdge.Hard, empty.TopEdge);
    }

    [Fact]
    public void TheDefaultsAreStoredAsNothing()
    {
        var prefs = new MemoryPrefs();
        var store = new ThemeStore(prefs);
        store.SetDensity(ListDensity.Compact);
        store.SetTopEdge(TopEdge.Soft);
        Assert.Equal("compact", prefs.Values["hqn.theme.density"]);
        Assert.Equal("soft", prefs.Values["hqn.theme.topEdge"]);
        var loaded = store.Load();
        Assert.Equal(ListDensity.Compact, loaded.Density);
        Assert.Equal(TopEdge.Soft, loaded.TopEdge);
        store.SetDensity(ListDensity.Standard);
        store.SetTopEdge(TopEdge.Hard);
        Assert.False(prefs.Values.ContainsKey("hqn.theme.density"));
        Assert.False(prefs.Values.ContainsKey("hqn.theme.topEdge"));
    }

    [Fact]
    public void AValueThisStoreDoesNotWriteReadsAsTheDefaultAndIsKept()
    {
        var prefs = new MemoryPrefs();
        prefs.Set("hqn.theme.density", "Compact");   // raw values are lower case
        prefs.Set("hqn.theme.topEdge", "medium");
        var loaded = new ThemeStore(prefs).Load();
        Assert.Equal(ListDensity.Standard, loaded.Density);
        Assert.Equal(TopEdge.Hard, loaded.TopEdge);
        Assert.Equal("Compact", prefs.Get("hqn.theme.density"));
        Assert.Equal("medium", prefs.Get("hqn.theme.topEdge"));
    }

    [Fact]
    public void ResetClearsBoth()
    {
        var prefs = new MemoryPrefs();
        var store = new ThemeStore(prefs);
        store.SetDensity(ListDensity.Compact);
        store.SetTopEdge(TopEdge.Soft);
        store.Reset();
        Assert.False(prefs.Values.ContainsKey("hqn.theme.density"));
        Assert.False(prefs.Values.ContainsKey("hqn.theme.topEdge"));
    }

    [Fact]
    public void CompactDrawsOnlyInTheIosLook()
    {
        var compact = ThemeState.Default with { Density = ListDensity.Compact };
        Assert.True(compact.Compact);
        Assert.False((compact with { DesktopLook = true }).Compact);
        Assert.False(ThemeState.Default.Compact);
    }

    // ---------------------------------------------------------------- words

    [Fact]
    public void DensityInTheMacsWords()
    {
        Assert.Equal("Density", DensityRow.Label);
        Assert.Equal("theme.density", DensityRow.AutomationId);
        Assert.Equal("row:density", DensityRow.RowTarget);
        Assert.Equal([("Standard", ListDensity.Standard), ("Compact", ListDensity.Compact)], DensityRow.Options);
        // The Mac's note (AppearanceSections.compactNote on the Mac: the sidebar's bots, not the Bots page).
        Assert.Equal("Compact fits more in the sidebar's bots and on the Sessions page: smaller faces and shorter rows.", DensityRow.CompactNote);
        Assert.True(DensityRow.Shown(ThemeState.Default));
        Assert.False(DensityRow.Shown(ThemeState.Default with { DesktopLook = true }));
        // `listsNote`: Compact's note (iOS look only), then Working Ring's.
        Assert.Equal(DensityRow.CompactNote + " " + WorkingRing.Note, DensityRow.ListsNote(ThemeState.Default));
        Assert.Equal(WorkingRing.Note, DensityRow.ListsNote(ThemeState.Default with { DesktopLook = true }));
    }

    [Fact]
    public void TopEdgeInTheMacsWordsAndNotOfferedOnTheDesktop()
    {
        Assert.Equal("Top Edge", TopEdgeRow.Label);
        Assert.Equal("theme.topEdge", TopEdgeRow.AutomationId);
        Assert.Equal("row:top-edge", TopEdgeRow.RowTarget);
        Assert.Equal([("Soft", TopEdge.Soft), ("Hard", TopEdge.Hard)], TopEdgeRow.Options);
        Assert.Equal("Where rows scroll under the top of every tab. Chats always fade softly. Soft blurs them out gradually. Hard is a frosted band with a straight bottom edge.",
            TopEdgeRow.Note);
        // TopEdgeStyle.offered is false on the Mac (its bars have a backing and draw no top edge): not on this desktop either.
        Assert.False(TopEdgeRow.Offered);
        Assert.False(TopEdgeRow.Shown(ThemeState.Default));
        Assert.False(TopEdgeRow.Shown(ThemeState.Default with { TopEdge = TopEdge.Soft }));
        // `TopEdgeStyle.current`: soft where it isn't offered, whatever was stored.
        Assert.Equal(TopEdge.Soft, TopEdgeRow.Applied(ThemeState.Default));
        Assert.Equal(TopEdge.Soft, TopEdgeRow.Applied(ThemeState.Default with { DesktopLook = true }));
    }

    [Fact]
    public void SettingsSearchFindsDensityOnAppearanceAndNoTopEdge()
    {
        var hit = Assert.Single(SettingsSearch.Index, e => e.Id == "app:density");
        Assert.Equal("Density", hit.Label);
        Assert.Equal("Appearance", hit.Context);
        Assert.Equal(["compact", "dense", "smaller rows", "fit more", "ui scale", "zoom", "smaller text"], hit.Keywords);
        Assert.Equal("row:density", hit.Target);
        Assert.Equal(SettingsCategory.Appearance, SettingsSearch.Category(hit.Target));
        Assert.Contains(SettingsSearch.Results("smaller rows", SettingsSearch.Index), e => e.Id == "app:density");
        // The Mac's index has no Top Edge entry (the row is never on the Mac).
        Assert.DoesNotContain(SettingsSearch.Index, e => e.Target == "row:top-edge" || e.Label == "Top Edge");
        // Order as the Mac's appRows: Working Ring, then Density.
        var ids = SettingsSearch.Index.Select(e => e.Id).ToList();
        Assert.Equal(ids.IndexOf("app:working-ring") + 1, ids.IndexOf("app:density"));
    }

    // ---------------------------------------------------------------- where it takes effect

    [Fact]
    public void TheOpenSidebarTakesBothMacPitchesAndCentersItsContent()
    {
        var standard = DensitySizes.Sidebar(compact: false);
        // Faces and titles are centred in the row at its native pitch; no extra top/bottom padding.
        const double dip = 0.77;
        Assert.Equal(new DensitySizes.SidebarSizes(34 * dip, 45.5 * dip, 19.5 * dip, 39 * dip, 36 * dip, 17 * dip), standard);
        var compact = DensitySizes.Sidebar(compact: true);
        Assert.Equal(new DensitySizes.SidebarSizes(28 * dip, 40 * dip, 18 * dip, 34 * dip, 32 * dip, 15.5 * dip), compact);
    }

    [Fact]
    public void SessionsRowsTakeTheMacsCompactStep()
    {
        Assert.Equal(new DensitySizes.SessionSizes(Row: 34, Pad: 5, Face: 22), DensitySizes.Sessions(compact: false));
        // macTight: the Mac's 36 pt rows with 6 over and under at Standard; Compact's 32 and 5; the owner's face 22 → 18.
        Assert.Equal(new DensitySizes.SessionSizes(Row: 30, Pad: 4, Face: 18), DensitySizes.Sessions(compact: true));
    }

    [Fact]
    public void ListsHearOnlyAChangeOfDrawnDensity()
    {
        var heard = 0;
        void Count() => heard++;
        DensitySizes.Changed += Count;
        try
        {
            var standard = ThemeState.Default;
            var compact = standard with { Density = ListDensity.Compact };
            Assert.False(DensitySizes.Notify(standard, standard));
            Assert.True(DensitySizes.Notify(standard, compact));
            Assert.False(DensitySizes.Notify(compact, compact with { UiScalePercent = 110 }));
            // Desktop Look on hides Compact: the lists redraw at standard.
            Assert.True(DensitySizes.Notify(compact, compact with { DesktopLook = true }));
            Assert.Equal(2, heard);
        }
        finally { DensitySizes.Changed -= Count; }
    }

    // ---------------------------------------------------------------- source (WinUI can't run here)

    private static string Source(params string[] parts)
    {
        var dir = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(dir, "HermesHQ.sln"))) dir = Path.GetDirectoryName(dir) ?? throw new InvalidOperationException("no windows dir");
        return File.ReadAllText(Path.Combine([dir, "src", "HermesHQ.Windows", .. parts])).Replace("\r\n", "\n");
    }

    private static string Body(string source, string signature) =>
        Regex.Match(source, Regex.Escape(signature) + @"(?<b>.*?)\n    \}", RegexOptions.Singleline).Groups["b"].Value;

    [Fact]
    public void AppearanceDrawsDensityFirstInBotsAndSessionsAndNoTopEdge()
    {
        var panes = Source("Features", "Settings", "SettingsPanes.cs");
        var appearance = Body(panes, "private static FrameworkElement Appearance(SettingsPage page)");
        Assert.Contains("Kit.Section(WorkingRing.SectionTitle, DensityRow.ListsNote(state), DensityRow.Shown(state) ? DensityControl(state) : null, WorkingRingRow())", appearance);
        Assert.DoesNotContain("TopEdge", appearance);
        var row = Body(panes, "private static FrameworkElement DensityControl(ThemeState state)");
        Assert.Contains("DensityRow.Label", row);
        Assert.Contains("DensityRow.Options", row);
        Assert.Contains("DensityRow.RowTarget", row);
        Assert.Contains("SetAutomationId(strip, DensityRow.AutomationId)", row);
        Assert.Contains("ThemeService.SetDensity(", row);
        var service = Source("Features", "Settings", "ThemeService.cs");
        Assert.Contains("public static void SetDensity(ListDensity density)", service);
        Assert.Contains("DensitySizes.Notify(was, State)", service);
    }

    [Fact]
    public void SidebarAndSessionsDrawAtTheDensityAndRedrawWhenItChanges()
    {
        var rows = Source("Shell", "SidebarItems.cs");
        Assert.Contains("DensitySizes.Sidebar(ThemeService.State.Compact)", rows);
        foreach (var use in new[] { "Face(bot, z.Face)", "z.BotRow", "z.PlaceRow", "z.ChatRow", "z.ChatTitle", "VerticalContentAlignment = VerticalAlignment.Center", "z.Name" })
            Assert.Contains(use, rows);
        var sessions = Source("Pages", "SessionsPage.xaml.cs");
        Assert.Contains("DensitySizes.Sessions(ThemeService.State.Compact)", sessions);
        foreach (var page in new[] { Source("Pages", "ShellPage.xaml.cs"), sessions })
        {
            Assert.Contains("DensitySizes.Changed += OnDensity", page);
            Assert.Contains("DensitySizes.Changed -= OnDensity", page);
        }
    }
}
