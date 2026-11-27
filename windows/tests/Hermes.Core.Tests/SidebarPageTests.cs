using System.Text.RegularExpressions;
using Hermes.Core.Bots;
using Hermes.Core.Settings;
using Hermes.Core.Shell;
using Xunit;

namespace Hermes.Core.Tests;

/// Settings › Appearance › Sidebar (the Mac's TabOrderPage at 93f984bb1, App/Settings/TabOrderPage.swift, with
/// HermesKit/Settings/TabOrder.swift and App/Mac/SidebarEditing.swift): the places in the sidebar with a switch each and
/// their order, the pages that can join them, Use Default Tabs, and the row that opens the page.
public class SidebarPageTests
{
    private static readonly List<PlaceInfo> All =
    [
        new("sessions", "Sessions", false), new("jobs", "Jobs", false), new("artifacts", "Artifacts", false),
        new("tasks", "Tasks", true), new("files", "Files", true), new("settings", "Settings", true),
    ];

    [Fact]
    public void TheMacsWordsForThePage()
    {
        Assert.Equal("Sidebar", SidebarPage.Title);
        Assert.Equal("sidebar", SidebarPage.Target);
        Assert.Equal("settings.tab-order", SidebarPage.RowId);
        Assert.Equal("App", SidebarPage.AppSection);
        Assert.Equal("Sidebar", SidebarPage.ShownHeader);
        Assert.Equal("Add to Sidebar", SidebarPage.AddHeader);
        Assert.Equal("Use Default Tabs", SidebarPage.UseDefault);
        Assert.Equal("tab-order.default", SidebarPage.UseDefaultId);
        // The Mac's addFooter, with DeviceWord.hold (\"Control‑click\") as Windows' right-click.
        Assert.Equal("These pages already show in the sidebar under Tools, or open from Settings. Turn one on to move it up "
            + "to the places above. You can also right-click a row under Tools and choose Move to Places.", SidebarPage.AddFooter);
    }

    [Fact]
    public void TheShownFooterSaysWhereChatsOpenWithSessionsHidden()
    {
        Assert.Equal("Bots or Sessions always stays: chats open there.", SidebarPage.ShownFooter(["sessions", "jobs"]));
        Assert.Equal("Bots or Sessions always stays: chats open there. With Sessions hidden, a chat opens on Bots.",
            SidebarPage.ShownFooter(["jobs"]));
    }

    [Fact]
    public void RowIdsAreTheMacsTabKeys()
    {
        Assert.Equal("tab-order.sessions", SidebarPage.RowAutomationId("sessions"));
        Assert.Equal("tab-order.jobs", SidebarPage.RowAutomationId("jobs"));
        Assert.Equal("tab-order.workspace", SidebarPage.RowAutomationId("artifacts"));   // tab 3, Kanban or Artifacts
        Assert.Equal("tab-order.page.files", SidebarPage.RowAutomationId("files"));
    }

    [Fact]
    public void AddRowsAreEveryPlaceNotShownButSettings()
    {
        var l = new SidebarLayout();
        // Tools and removed places, in the table's order; Settings is a window of its own (Mac polish #28).
        Assert.Equal(["tasks", "files"], l.AddRows(All).Select(p => p.Id));
        l.Remove("jobs", All);
        Assert.Equal(["jobs", "tasks", "files"], l.AddRows(All).Select(p => p.Id));
        l.Add("files", All);
        Assert.Equal(["jobs", "tasks"], l.AddRows(All).Select(p => p.Id));
        Assert.Equal(["sessions", "artifacts", "files"], l.Shown(All));
    }

    [Fact]
    public void UseDefaultTabsShowsOnlyAwayFromTheDefaultAndPutsItBack()
    {
        var l = new SidebarLayout();
        Assert.True(l.IsDefault(All));
        l.Move("jobs", 1, All);
        Assert.False(l.IsDefault(All));
        l.UseDefault();
        Assert.True(l.IsDefault(All));
        Assert.Null(l.Order);
        // An order that lists the default places in the default order is the default too.
        l.Order = ["sessions", "jobs", "artifacts"];
        Assert.True(l.IsDefault(All));
        l.Add("tasks", All);
        Assert.False(l.IsDefault(All));
        l.UseDefault();
        Assert.Equal(["tasks", "files"], l.Tools(All).Where(id => id != "settings"));
    }

    [Fact]
    public void ArrangeTakesTheDraggedOrderOfTheShownRows()
    {
        var l = new SidebarLayout();
        l.Arrange(["artifacts", "sessions", "jobs"], All);
        Assert.Equal(["artifacts", "sessions", "jobs"], l.Shown(All));
        // Ids not shown or unknown are ignored; a shown row the list left out keeps its place at the end.
        l.Arrange(["jobs", "nope", "tasks", "artifacts"], All);
        Assert.Equal(["jobs", "artifacts", "sessions"], l.Shown(All));
    }

    [Fact]
    public void ChangedIsRaisedForTheOtherWindow()
    {
        var hits = 0;
        void On() => hits++;
        SidebarLayout.Changed += On;
        try { SidebarLayout.NotifyChanged(); }
        finally { SidebarLayout.Changed -= On; }
        Assert.Equal(1, hits);
    }

    [Fact]
    public void SearchFindsTheSidebarPageOnAppearance()
    {
        var hit = SettingsSearch.Results("hide tabs", SettingsSearch.Index);
        var e = Assert.Single(hit);
        Assert.Equal("app:tab-order", e.Id);
        Assert.Equal("Sidebar", e.Label);
        Assert.Equal("Appearance", e.Context);
        Assert.Equal(SidebarPage.Target, e.Target);
        Assert.Equal(SettingsCategory.Appearance, SettingsSearch.Category(SidebarPage.Target));
        Assert.Contains(SettingsSearch.Results("reorder", SettingsSearch.Index), x => x.Id == "app:tab-order");
        var ids = SettingsSearch.Index.Select(x => x.Id).ToList();
        Assert.Equal(ids.IndexOf("app:appearance") + 1, ids.IndexOf("app:tab-order"));   // the Mac's index order
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
    public void TheSidebarRowIsInAnAppSectionLastOnAppearance()
    {
        var panes = Source("Features", "Settings", "SettingsPanes.cs");
        var appearance = Body(panes, "private static FrameworkElement Appearance(SettingsPage page)");
        var lists = appearance.IndexOf("Kit.Section(WorkingRing.SectionTitle", StringComparison.Ordinal);
        var app = appearance.IndexOf("Kit.Section(SidebarPage.AppSection, null,", StringComparison.Ordinal);
        Assert.True(lists >= 0 && app > lists, "Bots & Sessions, then App");
        Assert.Contains("Kit.Nav(GSidebar, SidebarPage.Title, null, () => Go(page, SidebarPage.Target), SidebarPage.RowId)", appearance);
        Assert.DoesNotContain("settings.sidebar-row", panes);
        Assert.Contains("SidebarPage.Target => (SidebarPage.Title, () => SidebarSettingsPage.Make())", panes);
    }

    [Fact]
    public void ThePageDrawsTheMacsSectionsInOrderAndTheSidebarFollows()
    {
        var page = Source("Features", "Settings", "SidebarSettingsPage.cs");
        var draw = Body(page, "private static void Draw(StackPanel root)");
        var shown = draw.IndexOf("ShownSection(layout, infos, shown)", StringComparison.Ordinal);
        var hooks = draw.IndexOf("SettingsHooks.Sidebar", StringComparison.Ordinal);
        var add = draw.IndexOf("Kit.Section(SidebarPage.AddHeader, SidebarPage.AddFooter,", StringComparison.Ordinal);
        var reset = draw.IndexOf("Kit.Push(SidebarPage.UseDefault,", StringComparison.Ordinal);
        Assert.True(shown >= 0 && hooks > shown && add > hooks && reset > add, "Sidebar, Jobs Badge, Add to Sidebar, Use Default Tabs");
        Assert.Contains("layout.AddRows(infos)", draw);
        Assert.Contains("if (!layout.IsDefault(infos))", draw);
        var section = Body(page, "private static StackPanel ShownSection(");
        Assert.Contains("Kit.Section(SidebarPage.ShownHeader, SidebarPage.ShownFooter(shown), list)", section);
        Assert.Contains("enabled: layout.CanRemove(id, infos)", section);
        Assert.Contains("SidebarPage.RowAutomationId(id)", page);
        Assert.Contains("CanReorderItems = true", page);
        Assert.Contains("layout.Arrange(", page);
        Assert.Contains("SidebarLayout.NotifyChanged()", page);
        Assert.Contains("SidebarLayout.Changed +=", page);
        var shell = Source("Pages", "ShellPage.xaml.cs");
        Assert.Contains("SidebarLayout.Changed += OnSidebarChanged", shell);
        Assert.Contains("SidebarLayout.Changed -= OnSidebarChanged", shell);
        Assert.Contains("SidebarLayout.NotifyChanged()", Body(shell, "private void SaveLayout()"));
    }
}
