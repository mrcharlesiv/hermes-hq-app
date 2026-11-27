using Hermes.Core.Bots;
using Hermes.Core.Sessions;
using Hermes.Core.Shell;

namespace Hermes.Core.Tests;

/// The New Chat sheet (App/Sessions/SessionsOrganizer.swift `compose`, `NewChatSheetView`, `NewChatAllProjectsView`;
/// App/Settings/AppPreferences.swift `NewChatLast`; HermesKit SessionStore+OwnFolder.swift `newChatEntries`).
public class NewChatSheetTests
{
    private static readonly NewChatBot[] Bots =
    [
        new("otto", "Otto"), new("default", "Hermes"), new("herald", "Herald"), new("ivy", "Ivy", Hidden: true),
    ];

    private static List<NewChatEntry> Entries(int n) =>
        Enumerable.Range(1, n).Select(i => new NewChatEntry($"/home/me/p{i}", $"Project {i}")).ToList();

    [Fact]
    public void TheWordsAreTheMacs()
    {
        Assert.Equal("New Chat", NewChatText.Title);
        Assert.Equal("Bot", NewChatText.BotHeading);
        Assert.Equal("In a project (optional)", NewChatText.ProjectHeading + NewChatText.ProjectHeadingOptional);
        Assert.Equal("In a folder", NewChatText.FolderHeading);
        Assert.Equal("Start Chat", NewChatText.Start);
        Assert.Equal("New Project…", NewChatText.NewProject);
        Assert.Equal("Last used", NewChatText.LastUsed);
        Assert.Equal("Start Chat with Otto", NewChatText.StartSpoken("Otto"));
        Assert.Equal("Starts the chat with Otto.", NewChatText.StartsWith("Otto"));
        Assert.Equal("All Projects", NewChatText.AllTitle(Entries(2)));
        Assert.Equal("All Projects and Folders", NewChatText.AllTitle([.. Entries(1), new("/x", "x", IsFolder: true)]));
        Assert.Equal("Search projects", NewChatText.SearchPlaceholder(Entries(2)));
        Assert.Equal("Search projects and folders", NewChatText.SearchPlaceholder([new("/x", "x", IsFolder: true)]));
        Assert.Equal("new-chat-bot-otto", NewChatText.BotId("otto"));
        Assert.Equal("new-chat-project-Project 1", NewChatText.RowId(Entries(1)[0]));
        Assert.Equal("new-chat-folder-x", NewChatText.RowId(new("/x", "x", IsFolder: true)));
        Assert.Equal("new-chat-start", NewChatText.StartId);
    }

    [Fact]
    public void PillsPutHermesFirstAndLeaveHiddenBotsOutUnlessPicked()
    {
        Assert.Equal(["default", "otto", "herald"], NewChatCompose.Offered(Bots, null).Select(b => b.Id));
        Assert.Equal(["default", "otto", "herald", "ivy"], NewChatCompose.Offered(Bots, "ivy").Select(b => b.Id));
        // Hermes is offered even when hidden.
        Assert.Contains(NewChatCompose.Offered([new("default", "Hermes", Hidden: true)], null), b => b.Id == "default");
    }

    [Fact]
    public void TheLitBotIsThePickedOneElseTheLastElseHermesElseTheFirst()
    {
        Assert.Equal("otto", NewChatLast.OpensOn("otto", "herald", ["default", "otto", "herald"]));
        Assert.Equal("herald", NewChatLast.OpensOn("gone", "herald", ["default", "otto", "herald"]));
        Assert.Equal("default", NewChatLast.OpensOn(null, "gone", ["otto", "default"]));
        Assert.Equal("otto", NewChatLast.OpensOn(null, null, ["otto", "herald"]));
        Assert.Equal("default", NewChatLast.OpensOn(null, null, []));

        var last = new NewChatLast(new MemoryDeviceStore());
        Assert.Equal("default", new NewChatSheetModel(Bots, [], null, last).Bot);
        last.Note("herald", null);
        var sheet = new NewChatSheetModel(Bots, [], null, last);
        Assert.Equal("herald", sheet.Bot);
        Assert.Equal("Start Chat with Herald", sheet.StartSpoken);
        Assert.Equal("otto", new NewChatSheetModel(Bots, [], "otto", last).Bot);
        // A hidden bot used last is not offered, so it is not lit.
        last.Note("ivy", null);
        Assert.Equal("default", new NewChatSheetModel(Bots, [], null, last).Bot);
    }

    [Fact]
    public void FewProjectsAreAllListedManyShowFiveRecentFirstAndAllProjects()
    {
        var six = Entries(6);
        var (keys, more) = NewChatLast.Shown(six.Select(e => e.Key).ToList(), ["/home/me/p4"]);
        Assert.Equal(six.Select(e => e.Key), keys);   // six or fewer: the list's own order, recents ignored
        Assert.False(more);

        var nine = Entries(9).Select(e => e.Key).ToList();
        (keys, more) = NewChatLast.Shown(nine, ["/home/me/p8", "/gone", "/home/me/p3", "/home/me/p8"]);
        Assert.True(more);
        Assert.Equal(["/home/me/p8", "/home/me/p3", "/home/me/p1", "/home/me/p2", "/home/me/p4"], keys);
    }

    [Fact]
    public void LastUsedMarksTheBotsLastProjectOrNoProject()
    {
        Assert.False(NewChatLast.Marks(null, "/a"));
        Assert.True(NewChatLast.Marks("/a", "/a"));
        Assert.False(NewChatLast.Marks("/a", "/b"));
        Assert.True(NewChatLast.Marks(NewChatLast.None, null));
        Assert.False(NewChatLast.Marks(NewChatLast.None, "/a"));
    }

    [Fact]
    public void NoteKeepsTheLastBotProjectAndEightRecentsNewestFirst()
    {
        var disk = new MemoryDeviceStore();
        var last = new NewChatLast(disk);
        for (var i = 1; i <= 10; i++) last.Note("otto", $"/p{i}");
        last.Note("otto", "/p3");
        Assert.Equal(["/p3", "/p10", "/p9", "/p8", "/p7", "/p6", "/p5", "/p4"], last.Recents("otto"));
        Assert.Equal("/p3", last.Project("otto"));
        last.Note("otto", null);
        Assert.Equal(NewChatLast.None, last.Project("otto"));
        Assert.Equal(8, last.Recents("otto").Count);   // No Project adds no recent
        Assert.Null(last.Project("herald"));
        // It is kept on the device under the Mac's keys.
        Assert.Equal("otto", new NewChatLast(disk).Bot);
        Assert.NotNull(disk.Read(NewChatLast.ProjectsKey));
        Assert.NotNull(disk.Read(NewChatLast.RecentsKey));
        disk.Write(NewChatLast.RecentsKey, "not json");
        Assert.Empty(new NewChatLast(disk).Recents("otto"));
    }

    [Fact]
    public void NewProjectKeepsTheBotsLastProject()
    {
        var last = new NewChatLast(new MemoryDeviceStore());
        last.Note("otto", "/p1");
        var sheet = new NewChatSheetModel(Bots, Entries(2), "otto", last);
        sheet.Note(NewChatCompose.NewProjectTag);
        Assert.Equal("/p1", last.Project("otto"));
        Assert.DoesNotContain(NewChatCompose.NewProjectTag, last.Recents("otto"));
        sheet.Bot = "herald";
        sheet.Note(NewChatCompose.NewProjectTag);   // nothing kept: No Project
        Assert.Equal(NewChatLast.None, last.Project("herald"));
        Assert.Equal("herald", last.Bot);
    }

    [Fact]
    public void LayoutPutsProjectsThenFoldersAllProjectsAndNewProjectWhereTheMacDoes()
    {
        var last = new NewChatLast(new MemoryDeviceStore());
        last.Note("default", "/home/me/p2");

        // Few saved projects: all of them, no All Projects, New Project… in a section of its own.
        var layout = new NewChatSheetModel(Bots, Entries(3), null, last).Layout();
        Assert.Equal(["Project 1", "Project 2", "Project 3"], layout.Projects.Select(r => r.Entry.Label));
        Assert.Equal([false, true, false], layout.Projects.Select(r => r.LastUsed));
        Assert.Empty(layout.Folders);
        Assert.False(layout.AllUnderProjects || layout.AllUnderFolders);
        Assert.False(layout.NewProjectInProjects);
        Assert.Equal("All Projects", layout.AllTitle);

        // Many: five and All Projects (with the count) under the projects.
        layout = new NewChatSheetModel(Bots, Entries(9), null, last, _ => ["/home/me/p7"]).Layout();
        Assert.Equal(["Project 7", "Project 1", "Project 2", "Project 3", "Project 4"], layout.Projects.Select(r => r.Entry.Label));
        Assert.True(layout.AllUnderProjects);
        Assert.Equal(9, layout.AllCount);

        // No saved project: New Project… stands in the projects' section; folders under "In a folder" with All Projects.
        var folders = Enumerable.Range(1, 8).Select(i => new NewChatEntry($"/f{i}", $"f{i}", IsFolder: true)).ToList();
        layout = new NewChatSheetModel(Bots, folders, null, last).Layout();
        Assert.Empty(layout.Projects);
        Assert.Equal(5, layout.Folders.Count);
        Assert.True(layout.NewProjectInProjects);
        Assert.True(layout.AllUnderFolders);
        Assert.False(layout.AllUnderProjects);
        Assert.Equal("All Projects and Folders", layout.AllTitle);

        // Nothing at all: only New Project…, in the projects' section.
        layout = new NewChatSheetModel(Bots, [], null, last).Layout();
        Assert.True(layout.NewProjectInProjects);
        Assert.Equal(0, layout.AllCount);
    }

    [Fact]
    public void AllProjectsIsAToZSavedThenFoldersAndSearches()
    {
        var entries = new List<NewChatEntry>
        {
            new("/z", "zebra"), new("/a", "Apple"), new("/c", "checkout", IsFolder: true), new("/b", "banana"),
        };
        var last = new NewChatLast(new MemoryDeviceStore());
        last.Note("default", "/b");
        var sheet = new NewChatSheetModel(Bots, entries, null, last);
        var all = sheet.All("");
        Assert.Equal(["Apple", "banana", "zebra"], all.Saved.Select(r => r.Entry.Label));
        Assert.Equal(["checkout"], all.Folders.Select(r => r.Entry.Label));
        Assert.True(all.Saved[1].LastUsed);
        Assert.Null(all.Empty);
        Assert.Equal(["banana"], sheet.All("  AN ").Saved.Select(r => r.Entry.Label));
        Assert.Equal("Nothing matches.", sheet.All("qq").Empty);
        Assert.Equal("No projects match.", new NewChatSheetModel(Bots, Entries(2), null, last).All("qq").Empty);
    }

    [Fact]
    public void ComposeStartsAtOnceWhereTheMacAsksNothing()
    {
        // Filter › Project on one project: the chat starts in it, no sheet.
        Assert.Equal(new NewChatStep.Direct("otto", "/home/me/site"),
            NewChatCompose.Decide(["/home/me/site"], "otto", asksProject: true, Bots));
        // On Home alone, or two projects: the sheet.
        Assert.IsType<NewChatStep.Sheet>(NewChatCompose.Decide([SessionProjects.HomeKey], null, false, Bots));
        Assert.IsType<NewChatStep.Sheet>(NewChatCompose.Decide(["/a", "/b"], null, false, Bots));
        // ⇧⌘N (no pick): the sheet. Compose with a picked chip (asks for a project): the sheet lit on it.
        Assert.Equal(new NewChatStep.Sheet(null), NewChatCompose.Decide([], null, false, Bots));
        Assert.Equal(new NewChatStep.Sheet("otto"), NewChatCompose.Decide([], "otto", asksProject: true, Bots));
        // A picked bot from a caller that is not the go-to, or with New Chat Asks for a Project off: no project, at once.
        Assert.Equal(new NewChatStep.Direct("otto", null), NewChatCompose.Decide([], "otto", asksProject: false, Bots));
        Assert.Equal(new NewChatStep.Direct("otto", null), NewChatCompose.Decide([], "otto", true, Bots, projectChoiceOn: false));
        // No bot to offer: a chat with Hermes at once.
        Assert.Equal(new NewChatStep.Direct("default", null), NewChatCompose.Decide([], null, false, []));
    }

    private static readonly Dictionary<string, List<SessionProject>> Tree = new()
    {
        ["default"] =
        [
            new("p_site", "Website", "/home/me/site/", ["/home/me/site"]),
            new("found", "checkout", "/home/me/code/checkout", [], IsAuto: true),
            new("own", "default", "/home/me/.hermes", [], IsAuto: true),
        ],
        ["otto"] =
        [
            new("p_app", "App", "/home/me/app", ["/home/me/app"]),
            new("own", "otto", "/home/me/.hermes/profiles/otto", [], IsAuto: true),
            new("p_nofolder", "Loose", "", []),
        ],
    };

    [Fact]
    public void EntriesAreSavedProjectsThenFoundFoldersWithoutABotsHome()
    {
        var entries = NewChatCompose.Entries(Tree, ["default", "otto"]);
        Assert.Equal(["App", "Loose", "Website", "checkout"], entries.Select(e => e.Label));
        Assert.Equal([false, false, false, true], entries.Select(e => e.IsFolder));
        Assert.Equal("/home/me/site", entries.Single(e => e.Label == "Website").Key);
        // A favorite is offered even when it is a bot's own folder.
        var fav = NewChatCompose.Entries(Tree, ["default"], new HashSet<string> { "/home/me/.hermes/profiles/otto" });
        Assert.Contains(fav, e => e.Key == "/home/me/.hermes/profiles/otto" && e.IsFolder);
        Assert.True(NewChatCompose.IsAnyProfileHome("/home/me/.hermes/"));
        Assert.False(NewChatCompose.IsAnyProfileHome("/home/me/.hermes/profiles/otto/work"));
    }

    [Fact]
    public void APickStartsInTheProjectsFolder()
    {
        Assert.Equal("/home/me/site/", NewChatCompose.Folder("/home/me/site", "default", Tree));   // the bot's own root
        Assert.Equal("/home/me/site", NewChatCompose.Folder("/home/me/site", "otto", Tree));       // another bot's: the folder
        Assert.Equal("/home/me/code/checkout", NewChatCompose.Folder("/home/me/code/checkout", "default", Tree));
        Assert.Null(NewChatCompose.Folder(null, "otto", Tree));
        Assert.Null(NewChatCompose.Folder(SessionProjects.HomeKey, "otto", Tree));
        Assert.Null(NewChatCompose.Folder("id:otto/p_nofolder", "otto", Tree));
    }

    [Fact]
    public void RecentIsFavoritesThenTheSheetsThenTheBotsNewestChats()
    {
        var last = new NewChatLast(new MemoryDeviceStore());
        last.Note("otto", "/home/me/site");
        var now = DateTimeOffset.UtcNow;
        SessionSummary Chat(string id, string profile, string cwd, int minutesAgo) =>
            new() { Id = id, Profile = profile, Title = id, Cwd = cwd, LastActive = now.AddMinutes(-minutesAgo) };
        var chats = new[] { Chat("a", "otto", "/home/me/zzz", 30), Chat("b", "otto", "/home/me/app/src", 5), Chat("c", "default", "/home/me/site", 1) };
        var recent = NewChatCompose.Recent("otto", last, chats, Tree, ["/fav"]).ToList();
        Assert.Equal(["/fav", "/home/me/site", "/home/me/app", SessionProjects.HomeKey], recent);
    }

    [Fact]
    public void CtrlShiftNIsNewChatWithAndRegistered()
    {
        Assert.Equal(new KeyChord("N", Ctrl: true, Shift: true), ShellKeys.NewChatWith);
        var row = KeyShortcuts.MacCatalogue.Single(s => s.Title == "File").Rows.Single(r => r.Title == "New Chat With…");
        Assert.Equal([ShellKeys.NewChatWith], row.Windows);
        Assert.Null(row.Gap);
        Assert.Contains(KeyShortcuts.Registered, r => r.Chord == ShellKeys.NewChatWith && r.Source == "Pages/ShellPage.xaml.cs");
    }

    // ------------------------------------------------------------------ keys on a bot's pill (WIN-30A)

    /// Space on a pill lights that bot and starts nothing (SwiftUI's pill button: `bot = item.id`); only Return (the
    /// sheet's `onReturn`, `NewChatKeysPage`) or Start Chat starts, and with the lit bot.
    [Fact]
    public void SpaceOnAPillLightsItAndStartsNothing()
    {
        var sheet = new NewChatSheetModel(Bots, Entries(2), null, new NewChatLast(new MemoryDeviceStore()));
        Assert.Equal("default", sheet.Bot);
        Assert.Equal(NewChatKeyAction.Select, sheet.PillKey("herald", NewChatKey.Space));
        Assert.Equal("herald", sheet.Bot);
        Assert.Equal(1, sheet.Bots.Count(b => b.Id == sheet.Bot));
    }

    /// Space on the pill already lit keeps it lit (a ToggleButton's own Space would have turned it off).
    [Fact]
    public void SpaceOnTheLitPillKeepsItLit()
    {
        var sheet = new NewChatSheetModel(Bots, [], null, new NewChatLast(new MemoryDeviceStore()));
        Assert.Equal(NewChatKeyAction.Select, sheet.PillKey("default", NewChatKey.Space));
        Assert.Equal("default", sheet.Bot);
    }

    /// Return on any pill starts the chat with the lit bot (the Mac's `page.onReturn = { pick(box.bot, nil) }`), even
    /// when the pill under the keyboard is another bot's.
    [Fact]
    public void ReturnOnAPillStartsWithTheLitBot()
    {
        var sheet = new NewChatSheetModel(Bots, [], null, new NewChatLast(new MemoryDeviceStore()));
        sheet.PillKey("otto", NewChatKey.Space);
        Assert.Equal(NewChatKeyAction.Start, sheet.PillKey("herald", NewChatKey.Enter));
        Assert.Equal("otto", sheet.Bot);
    }

    /// Other keys (arrows, Tab, letters) are the pill's and the dialog's own; a pill nobody offers changes nothing.
    [Fact]
    public void OtherKeysAndUnknownBotsLeaveTheSheetAlone()
    {
        var sheet = new NewChatSheetModel(Bots, [], null, new NewChatLast(new MemoryDeviceStore()));
        Assert.Equal(NewChatKeyAction.None, sheet.PillKey("otto", NewChatKey.Other));
        Assert.Equal("default", sheet.Bot);
        Assert.Equal(NewChatKeyAction.None, sheet.PillKey("nobody", NewChatKey.Space));
        Assert.Equal("default", sheet.Bot);
    }

    /// Space's and Return's release on a pill are the sheet's too, so the ToggleButton under them never clicks.
    [Fact]
    public void SpaceAndReturnReleasesAreSwallowed()
    {
        Assert.True(NewChatSheetModel.SwallowsRelease(NewChatKey.Space));
        Assert.True(NewChatSheetModel.SwallowsRelease(NewChatKey.Enter));
        Assert.False(NewChatSheetModel.SwallowsRelease(NewChatKey.Other));
    }
}
