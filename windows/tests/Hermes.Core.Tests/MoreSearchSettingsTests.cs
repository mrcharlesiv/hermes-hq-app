using Hermes.Core.BotPages;
using Hermes.Core.Settings;
using Hermes.Core.Shell;

namespace Hermes.Core.Tests;

/// Open Quickly / More search's Settings group (App/Pages/More/MoreSearchUI.swift:242-251 and
/// HermesKit/Pages/More/MoreSearch.swift:104-109 at 93f984bb1): the Settings index without its file actions, found as
/// Settings' own search finds it (pages first, then index order, one row per label and place, at most six), each row
/// "Settings › <context>" ("Settings" for a page with no context). A picked row opens its entry's target in Settings
/// (MacOpenQuickly.swift:450-461, MoreSearchUI.swift:337-343), not its id.
public class MoreSearchSettingsTests
{
    private static IReadOnlyList<MoreSearch.Group> Find(string query) =>
        MoreSearch.Results(query, [], [], [], MoreSearch.SettingsShown(SettingsSearch.Index), []);

    private static MoreSearch.Group? SettingsGroup(string query) =>
        Find(query).SingleOrDefault(g => g.Kind == MoreSearch.Kind.Settings);

    [Fact]
    public void TheIndexWithoutItsFileActions()
    {
        var shown = MoreSearch.SettingsShown(SettingsSearch.Index);
        Assert.DoesNotContain(shown, e => e.Id.StartsWith("action:", StringComparison.Ordinal));
        Assert.DoesNotContain(shown, e => SettingsSearch.ActionId(e.Target) != null);
        Assert.Equal(SettingsSearch.Index.Where(e => SettingsSearch.ActionId(e.Target) == null).Select(e => e.Id), shown.Select(e => e.Id));
        Assert.Contains(shown, e => e.Id == "app:ui-scale");
    }

    [Fact]
    public void ARowIsItsLabelUnderSettingsAndItsPlace()
    {
        var group = SettingsGroup("ui scale");
        Assert.NotNull(group);
        // [density] As the Mac's index: Density's keywords hold "ui scale" and it stands before UI Scale.
        Assert.Equal([new MoreSearch.Item("app:density", "Density", "Settings › Appearance"), new MoreSearch.Item("app:ui-scale", "UI Scale", "Settings › Theme")],
            group.Rows);
        Assert.Equal("Settings", MoreSearch.Title(group.Kind));
    }

    /// "about": the About page first (no context, so just "Settings"), then the rows on About in the index's order.
    [Fact]
    public void PagesFirstThenIndexOrder()
    {
        var group = SettingsGroup("about")!;
        Assert.Equal(["page:about", "app:diagnostics", "app:detailed-log", "app:licenses"], group.Rows.Select(r => r.Id));
        Assert.Equal("Settings", group.Rows[0].Detail);
        Assert.Equal("Settings › About", group.Rows[1].Detail);
        Assert.Equal(group.Rows.Count, group.Total);
    }

    /// Settings' own order, not More's scores: Share Logs (a title word "logs") stays after the two rows above it.
    [Fact]
    public void NotReRankedByMoreScores()
    {
        Assert.Equal(["app:diagnostics", "app:detailed-log", "app:share-logs"], SettingsGroup("logs")!.Rows.Select(r => r.Id));
    }

    /// The file actions are About's buttons, not Open Quickly rows (MoreSearchUI.swift:243 drops `.action`).
    [Theory]
    [InlineData("export", new string[0])]
    [InlineData("import", new string[0])]
    [InlineData("factory", new string[0])]
    [InlineData("backup", new string[0])]
    [InlineData("reset", new[] { "app:sound" })]   // Sound's "preset", as the Mac's substring match finds it
    public void NoFileActionRows(string query, string[] ids)
    {
        Assert.DoesNotContain(Find(query).SelectMany(g => g.Rows), r => r.Id.StartsWith("action:", StringComparison.Ordinal));
        Assert.Equal(ids, SettingsGroup(query)?.Rows.Select(r => r.Id) ?? []);
    }

    /// The word "Settings" in a row's detail is not something to find it by (the Mac matches label, place and keywords).
    [Fact]
    public void TheWordSettingsAloneFindsNoSettingsRow() => Assert.Null(SettingsGroup("settings"));

    [Fact]
    public void AtMostSixRows()
    {
        var group = SettingsGroup("a")!;
        Assert.Equal(MoreSearch.Limit, group.Rows.Count);
        Assert.Equal(MoreSearch.Limit, group.Total);
    }

    /// A picked row opens its entry's target in Settings ("row:ui-scale", "about", "about:detailed-log"), not its id.
    [Theory]
    // [density] "ui scale" now finds Density first, as the Mac's index; UI Scale's own words still lead to it.
    [InlineData("text size", "app:ui-scale", "row:ui-scale")]
    [InlineData("smaller rows", "app:density", "row:density")]
    [InlineData("default project folder", "app:default-folder", "sessions")]
    [InlineData("about", "page:about", "about")]
    [InlineData("verbose", "app:detailed-log", "about:detailed-log")]
    [InlineData("tapback", "app:message-reactions", "row:message-reactions")]
    [InlineData("rose pine", "app:theme", "theme")]
    public void APickedRowOpensItsTargetInSettings(string query, string id, string target)
    {
        var row = SettingsGroup(query)!.Rows[0];
        Assert.Equal(id, row.Id);
        Assert.Equal(new OpenQuickly.OpenSettings(target), OpenQuickly.Route(MoreSearch.Kind.Settings, row));
    }

    [Fact]
    public void AnUnknownSettingOpensNothing() =>
        Assert.Null(OpenQuickly.Route(MoreSearch.Kind.Settings, new MoreSearch.Item("theme", "Theme")));

    /// Every row the group can show routes somewhere in Settings.
    [Fact]
    public void EveryShownEntryRoutes()
    {
        foreach (var e in MoreSearch.SettingsShown(SettingsSearch.Index))
            Assert.Equal(new OpenQuickly.OpenSettings(e.Target),
                OpenQuickly.Route(MoreSearch.Kind.Settings, MoreSearch.SettingsItem(e)));
    }
}
