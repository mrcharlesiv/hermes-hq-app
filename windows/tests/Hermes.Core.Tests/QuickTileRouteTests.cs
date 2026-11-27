// [quick-actions] Where a Quick Actions tile goes, what's missing for it, the grid's rows, Add Action's groups and Set
// Up's rules: ports of the Mac's Tests/Intents/QuickTilesTests.swift route / rules / grid cases, plus the Windows
// build's own routes (QuickTileRules.Windows) and the page's edits persisted through QuickTileStore. Synthetic data only.
using Hermes.Core.Composer;
using Hermes.Core.QuickActions;

namespace Hermes.Core.Tests;

public class QuickTileRouteTests
{
    private static readonly QuickTileWorld Otto = new(
        Bots: new Dictionary<string, string> { ["otto"] = "Otto" },
        Jobs: new HashSet<string> { "otto|nightly" },
        Pages: new Dictionary<string, string> { ["jobs"] = "Jobs" });

    private static QuickTile Tile(QuickTileKind kind, string? bot = "otto", string id = "t1") =>
        QuickTile.Create(kind, id: id) with { Bot = bot, BotName = bot == null ? null : "Otto" };

    [Fact]
    public void EachKindRoutesAsItsShortcutTwin()
    {
        Assert.Equal(new QuickTileRoute.NewChat("otto", null, null, true), QuickTileRoute.Make(Tile(QuickTileKind.NewChat), Otto));
        Assert.Equal(new QuickTileRoute.NewChat("otto", "site", "hi", false),
            QuickTileRoute.Make(Tile(QuickTileKind.NewChat) with { Project = "site", Message = "hi", Flag = false }, Otto));
        Assert.Equal(new QuickTileRoute.Memo("otto"), QuickTileRoute.Make(Tile(QuickTileKind.Memo), Otto));
        Assert.Equal(new QuickTileRoute.Talk("otto"), QuickTileRoute.Make(Tile(QuickTileKind.Talk), Otto));
        Assert.Equal(new QuickTileRoute.OpenChat("otto"), QuickTileRoute.Make(Tile(QuickTileKind.OpenChat), Otto));
        Assert.Equal(new QuickTileRoute.SendInChat("otto", "status?"),
            QuickTileRoute.Make(Tile(QuickTileKind.Send) with { Message = "status?", Flag = true }, Otto));
        Assert.Equal(new QuickTileRoute.SendInBackground("otto", "status?"),
            QuickTileRoute.Make(Tile(QuickTileKind.Send) with { Message = "status?" }, Otto));
        Assert.Equal(new QuickTileRoute.Unavailable("Add the words to send in Edit."),
            QuickTileRoute.Make(Tile(QuickTileKind.Send) with { Message = "  " }, Otto));
        Assert.Equal(new QuickTileRoute.NewTask(null), QuickTileRoute.Make(Tile(QuickTileKind.AddTask, bot: null), Otto));
        Assert.Equal(new QuickTileRoute.NewTask("otto"), QuickTileRoute.Make(Tile(QuickTileKind.AddTask), Otto));
        Assert.Equal(new QuickTileRoute.RunJob("otto|nightly", "Nightly"),
            QuickTileRoute.Make(Tile(QuickTileKind.RunJob, bot: null) with { Job = "otto|nightly", JobName = "Nightly" }, Otto));
        Assert.Equal(new QuickTileRoute.Page("jobs"), QuickTileRoute.Make(Tile(QuickTileKind.Page, bot: null) with { Page = "jobs" }, Otto));
        Assert.Equal(new QuickTileRoute.Search(), QuickTileRoute.Make(Tile(QuickTileKind.Search, bot: null), Otto));
        Assert.True(new QuickTileRoute.SendInBackground("a", "b").StaysOnPage);
        Assert.False(new QuickTileRoute.Search().StaysOnPage);
    }

    [Fact]
    public void MissingTargetsSayOneSentenceAndUnknownWorldIsNeverMissing()
    {
        Assert.Equal("Herald isn’t on this gateway.",
            QuickTileRules.Missing(Tile(QuickTileKind.Memo, bot: "herald") with { BotName = "Herald" }, Otto));
        Assert.Null(QuickTileRules.Missing(Tile(QuickTileKind.Memo, bot: "herald"), new QuickTileWorld()));
        Assert.Equal("Choose a bot for this action in Edit.", QuickTileRules.Missing(Tile(QuickTileKind.Talk, bot: null), Otto));
        Assert.Null(QuickTileRules.Missing(Tile(QuickTileKind.AddTask, bot: null), Otto));
        Assert.Equal("Choose a job for this action in Edit.", QuickTileRules.Missing(Tile(QuickTileKind.RunJob, bot: null), Otto));
        Assert.Equal("“Backup” isn’t on this gateway.",
            QuickTileRules.Missing(Tile(QuickTileKind.RunJob, bot: null) with { Job = "otto|gone", JobName = "Backup" }, Otto));
        Assert.Equal("Choose a page for this action in Edit.", QuickTileRules.Missing(Tile(QuickTileKind.Page, bot: null), Otto));
        Assert.Equal("Usage isn’t on this gateway.",
            QuickTileRules.Missing(Tile(QuickTileKind.Page, bot: null) with { Page = "usage", PageName = "Usage" }, Otto));
        Assert.Equal(QuickTileRules.NewerApp, QuickTileRules.Missing(QuickTile.Create(QuickTileKind.Search) with { Kind = "teleport" }, Otto));
        Assert.Equal(new QuickTileRoute.Unavailable("Herald isn’t on this gateway."),
            QuickTileRoute.Make(Tile(QuickTileKind.OpenChat, bot: "herald") with { BotName = "Herald" }, Otto));
    }

    [Fact]
    public void WindowsRunsOnlyKindsItHasARouteFor()
    {
        var runs = QuickTileRules.Windows;
        foreach (var kind in new[] { QuickTileKind.Memo, QuickTileKind.Talk })
        {
            var tile = Tile(kind) with { Message = "x", Job = "otto|nightly" };
            Assert.Equal(new QuickTileRoute.Unavailable(QuickTileRules.NewerApp), QuickTileRoute.Make(tile, Otto, runs));
        }
        // [WIN-24] Send a Message and Run Job run on Windows (QuickTileRunTests has their routes).
        Assert.Equal(new QuickTileRoute.SendInBackground("otto", "x"), QuickTileRoute.Make(Tile(QuickTileKind.Send) with { Message = "x" }, Otto, runs));
        Assert.Equal(new QuickTileRoute.RunJob("otto|nightly", "Run Job"),
            QuickTileRoute.Make(Tile(QuickTileKind.RunJob, bot: null) with { Job = "otto|nightly" }, Otto, runs));
        Assert.Equal(new QuickTileRoute.OpenChat("otto"), QuickTileRoute.Make(Tile(QuickTileKind.OpenChat), Otto, runs));
        Assert.Equal(new QuickTileRoute.Search(), QuickTileRoute.Make(Tile(QuickTileKind.Search, bot: null), Otto, runs));
        // The seeded starter set: Memo and Talk are drawn switched off on Windows, the rest run.
        var starter = QuickTileStore.Starter("otto", "Otto");
        Assert.Equal([true, true, false, false, false], starter.Select(t => QuickTileRules.Missing(t, Otto, runs) != null));
    }

    [Fact]
    public void GridPutsWideTilesOnTheirOwnRowAndNeverReorders()
    {
        var starter = QuickTileStore.Starter("otto", "Otto");
        Assert.Equal([[0, 1], [2], [3, 4]], QuickTileGrid.Rows(starter, 2).Select(r => r.ToArray()));
        var lone = new[] { Tile(QuickTileKind.Memo, id: "a"), Tile(QuickTileKind.Talk, id: "b") with { Wide = true }, Tile(QuickTileKind.Search, id: "c") };
        Assert.Equal([[0], [1], [2]], QuickTileGrid.Rows(lone, 2).Select(r => r.ToArray()));
        Assert.Equal([[0], [1], [2], [3], [4]], QuickTileGrid.Rows(starter, 1).Select(r => r.ToArray()));
        Assert.Empty(QuickTileGrid.Rows([], 2));
    }

    [Fact]
    public void AddActionListsTheMacsGroupsInItsWords()
    {
        var pages = QuickActionChoice.Pages([("jobs", "Jobs", "Sidebar"), ("quick-actions", "Quick Actions", "Sidebar"), ("jobs", "Jobs", "Sidebar")]);
        Assert.Equal(["Jobs", "Search Chats"], pages.Select(p => p.Title));
        var all = QuickActionChoice.Groups(pages);
        Assert.Equal(["Chats", "Work", "Pages"], all.Select(g => g.Header));
        Assert.Equal(["New Chat", "Voice Memo", "Talk", "Send a Message", "Open a Chat"], all[0].Rows.Select(r => r.Title));
        Assert.Equal(["Add Task", "Run Job"], all[1].Rows.Select(r => r.Title));
        var windows = QuickActionChoice.Groups(pages, runs: QuickTileRules.Windows);
        Assert.Equal(["New Chat", "Send a Message", "Open a Chat"], windows[0].Rows.Select(r => r.Title));
        Assert.Equal(["Add Task", "Run Job"], windows[1].Rows.Select(r => r.Title));
        Assert.Equal(["Search Chats"], QuickActionChoice.Groups(pages, "search").SelectMany(g => g.Rows).Select(r => r.Title));
        Assert.Empty(QuickActionChoice.Groups(pages, "zzz"));
        Assert.Equal("No actions or pages match “zzz”.", QuickActionChoice.NoMatch("zzz"));
        var jobsTile = pages[0].NewTile();
        Assert.Equal(("page", "jobs", "Jobs", "Jobs"), (jobsTile.Kind, jobsTile.Page, jobsTile.PageName, jobsTile.Name));
        Assert.Equal("Open Chat", QuickActionChoice.Chats[4].NewTile().Name);
    }

    [Fact]
    public void SetUpSavesOnlyACompleteTileTrimmed()
    {
        Assert.False(QuickTileDraft.CanSave(Tile(QuickTileKind.Memo) with { Name = "  " }));
        Assert.False(QuickTileDraft.CanSave(Tile(QuickTileKind.Memo, bot: null)));
        Assert.True(QuickTileDraft.CanSave(Tile(QuickTileKind.Memo)));
        Assert.False(QuickTileDraft.CanSave(Tile(QuickTileKind.Send)));
        Assert.True(QuickTileDraft.CanSave(Tile(QuickTileKind.Send) with { Message = "go" }));
        Assert.False(QuickTileDraft.CanSave(Tile(QuickTileKind.Page, bot: null)));
        Assert.True(QuickTileDraft.CanSave(Tile(QuickTileKind.AddTask, bot: null)));
        var done = QuickTileDraft.Finished(Tile(QuickTileKind.NewChat) with { Name = " Ask Otto ", Message = "  \n" });
        Assert.Equal(("Ask Otto", (string?)null), (done.Name, done.Message));
    }

    /// The page's edits (add, replace, remove, reorder, Small/Wide) go through QuickTileStore and read back the same.
    [Fact]
    public void PageEditsPersistThroughTheStore()
    {
        var store = new MemoryStore();
        var (list, seeded) = QuickTileStore.ListToShow(QuickTileStore.Load(store), ("otto", "Otto"));
        Assert.True(seeded);
        QuickTileStore.Save(list, store);
        var added = QuickActionChoice.Pages([("jobs", "Jobs", "Sidebar")])[0].NewTile();
        list = QuickTileStore.Load(store);
        list.Add(added);
        list.Remove("starter-talk");
        list.Replace(list.Tiles[0] with { Name = "Note" });
        list.Step(added.Id, -1);
        list.SetWide("starter-search", true);
        Assert.True(QuickTileStore.Save(list, store));
        var back = QuickTileStore.Load(store);
        Assert.Equal(["starter-memo", "starter-new-chat", "starter-add-task", added.Id, "starter-search"], back.Tiles.Select(t => t.Id));
        Assert.Equal("Note", back.Tiles[0].Name);
        Assert.True(back.Tiles[4].Wide);
        // Removing every tile leaves an empty, seeded list: the starter set never comes back.
        foreach (var t in back.Tiles.ToList()) back.Remove(t.Id);
        QuickTileStore.Save(back, store);
        Assert.False(QuickTileStore.ListToShow(QuickTileStore.Load(store), ("otto", "Otto")).Seeded);
        Assert.Empty(QuickTileStore.Load(store).Tiles);
    }

    /// Wired in: the feature registers once (before the proof walks), its page is a Bindable code-only place, and
    /// Ctrl+Shift+K opens that place.
    [Fact]
    public void ThePageIsRegisteredAndCtrlShiftKOpensIt()
    {
        string root = AppContext.BaseDirectory;
        for (var dir = new DirectoryInfo(root); dir != null; dir = dir.Parent)
            if (File.Exists(Path.Combine(dir.FullName, "windows", "HermesHQ.sln"))) { root = dir.FullName; break; }
        var app = Path.Combine(root, "windows", "src", "HermesHQ.Windows");
        var registry = File.ReadAllText(Path.Combine(app, "Shell", "FeatureRegistry.cs"));
        var line = "HermesHQ.Features.QuickActions.QuickActionsFeature.Register();";
        Assert.True(registry.IndexOf(line, StringComparison.Ordinal) is var at && at > 0 && at < registry.IndexOf("ProofWalks.Register()", StringComparison.Ordinal));
        var page = File.ReadAllText(Path.Combine(app, "Features", "QuickActions", "QuickActionsPage.cs"));
        Assert.Contains("[Microsoft.UI.Xaml.Data.Bindable]\npublic sealed partial class QuickActionsPage : Page", page.Replace("\r\n", "\n"));
        Assert.Contains("Places.Register(PlaceId, typeof(QuickActionsPage));", File.ReadAllText(Path.Combine(app, "Features", "QuickActions", "QuickActionsFeature.cs")));
        Assert.Equal("quick-actions", QuickTileStore.RowID);
        Assert.Contains("AddShortcut(ShellKeys.QuickActions, () => Navigator.Open(\"quick-actions\"));", File.ReadAllText(Path.Combine(app, "Pages", "ShellPage.xaml.cs")));
        Assert.Equal(new Hermes.Core.Shell.KeyChord("K", Ctrl: true, Shift: true), Hermes.Core.Shell.ShellKeys.QuickActions);
        // No other key the app registers is Ctrl+Shift+K.
        Assert.Single(Hermes.Core.Shell.KeyShortcuts.Registered, r => r.Chord == Hermes.Core.Shell.ShellKeys.QuickActions);
    }
}
