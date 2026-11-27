using System.Text.Json.Nodes;
using Hermes.Core.Model;
using Hermes.Core.Net;
using Hermes.Core.Transcripts;
using Hermes.Core.Workspace;

namespace Hermes.Core.Tests;

/// More › Files and Changes (App/Pages/More/Workspace/MoreWorkspacePages.swift, HermesKit/Pages/More/MoreWorkspaceRoot.swift,
/// HermesKit/Chat/ChatWorkspace.swift): the root's precedence, the words, and the reads over a stand-in REST lane.
public class WorkspaceTests
{
    internal sealed class Prefs : IPreferences
    {
        public readonly Dictionary<string, string> Values = [];
        public string? Get(string key) => Values.GetValueOrDefault(key);
        public void Set(string key, string? value) { if (value == null) Values.Remove(key); else Values[key] = value; }
    }

    /// Answers by path from a table; records every request.
    internal sealed class Rest : IWorkspaceRest
    {
        public readonly Dictionary<string, Func<Dictionary<string, string>, (int, string)>> Routes = [];
        public readonly List<string> Asked = [];
        public Task<(int Status, string Body)> GetAsync(string path, IReadOnlyList<KeyValuePair<string, string>> query, CancellationToken ct)
        {
            var q = query.ToDictionary(k => k.Key, k => k.Value);
            Asked.Add(path + "?" + string.Join("&", query.Select(k => k.Key + "=" + k.Value)));
            return Task.FromResult(Routes.TryGetValue(path, out var f) ? f(q) : (404, "{\"detail\":\"Not Found\"}"));
        }
        public Task DownloadToFileAsync(string path, IReadOnlyList<KeyValuePair<string, string>> query, string file, long ceiling, CancellationToken ct)
        {
            File.WriteAllText(file, "bytes");
            return Task.CompletedTask;
        }
    }

    private static Bot B(string name, bool isDefault = false) =>
        new(name, name == "default" ? "Hermes" : char.ToUpperInvariant(name[0]) + name[1..], null, null, isDefault, false, false, null, false, null, null);

    [Fact]
    public void RootPrecedenceIsChosenThenChatThenGateway()
    {
        Assert.Equal(new WorkspaceRoot.Root("/a", WorkspaceRoot.Source.Chosen), WorkspaceRoot.Resolve("/a/", "/b", "/c"));
        Assert.Equal(new WorkspaceRoot.Root("/b", WorkspaceRoot.Source.Chat), WorkspaceRoot.Resolve("relative", " /b ", "/c"));
        Assert.Equal(new WorkspaceRoot.Root("/c", WorkspaceRoot.Source.Gateway), WorkspaceRoot.Resolve(null, null, "/c"));
        Assert.Null(WorkspaceRoot.Resolve(null, "", "~/x"));
        Assert.Equal("/", WorkspaceRoot.Folder("///"));
        Assert.True(WorkspaceRoot.NeedsGatewayDefault(null, "x"));
        Assert.False(WorkspaceRoot.NeedsGatewayDefault(null, "/x"));
    }

    [Fact]
    public void ChosenFolderIsKeptPerAccountAndBot()
    {
        var prefs = new Prefs();
        WorkspaceRoot.SetChosen(prefs, "/home/hermes/site/", "acct", "");
        Assert.Equal("/home/hermes/site", prefs.Values["pages.filesRoot.acct.default"]);
        Assert.Equal("/home/hermes/site", WorkspaceRoot.Chosen(prefs, "acct", "default"));
        Assert.Null(WorkspaceRoot.Chosen(prefs, "acct", "ivy"));
        WorkspaceRoot.SetChosen(prefs, null, "acct", "default");   // Use Chat’s Folder
        Assert.Empty(prefs.Values);
    }

    [Fact]
    public void PathsInWords()
    {
        Assert.Equal("/home/hermes", WorkspaceRoot.GatewayHome("/home/hermes/.hermes"));
        Assert.Equal("/home/hermes", WorkspaceRoot.GatewayHome("/home/hermes/.hermes/profiles/ivy"));
        Assert.Null(WorkspaceRoot.GatewayHome("/home/hermes/.hermesx"));
        Assert.Null(WorkspaceRoot.GatewayHome("/.hermes"));
        var profiles = JsonNode.Parse("""{"profiles":[{"name":"ivy","path":"/x/.hermes/profiles/ivy"},{"name":"default","path":"/Users/me/.hermes","is_default":true}]}""");
        Assert.Equal("/Users/me", WorkspaceRoot.GatewayHome(profiles));
        Assert.Equal("~/Projects/app", WorkspaceRoot.Display("/Users/me/Projects/app/", "/Users/me"));
        Assert.Equal("~", WorkspaceRoot.Display("/Users/me", "/Users/me"));
        Assert.Equal("/Users/mex/x", WorkspaceRoot.Display("/Users/mex/x", "/Users/me"));
        Assert.Equal("site", WorkspaceRoot.Name("/home/site"));
        Assert.Equal("/", WorkspaceRoot.Name("/"));
        Assert.Equal("/home", WorkspaceRoot.Parent("/home/site"));
        Assert.Equal("/", WorkspaceRoot.Parent("/home"));
        Assert.Null(WorkspaceRoot.Parent("/"));
        Assert.Equal([("site", "/p/site"), ("src", "/p/site/src"), ("deep", "/p/site/src/deep")],
            WorkspaceRoot.Crumbs("/p/site", "/p/site/src/deep"));
        Assert.Single(WorkspaceRoot.Crumbs("/p/site", "/elsewhere"));
    }

    [Fact]
    public void SourceAndFailureWords()
    {
        Assert.Equal("Folder you chose", WorkspaceRoot.SourceLine(WorkspaceRoot.Source.Chosen, null));
        Assert.Equal("The folder of “Trip”", WorkspaceRoot.SourceLine(WorkspaceRoot.Source.Chat, " Trip "));
        Assert.Equal("The folder of your last chat", WorkspaceRoot.SourceLine(WorkspaceRoot.Source.Chat, null));
        Assert.Equal("The default folder on the computer running Hermes", WorkspaceRoot.SourceLine(WorkspaceRoot.Source.Gateway, null));
        Assert.Equal(new WorkspaceRoot.Words("Folder Not Found", "This chat’s folder no longer exists on the computer running Hermes."),
            WorkspaceRoot.FolderErrorText("ENOENT: no such file", chatFolder: true));
        Assert.Equal("Couldn’t Read This Folder", WorkspaceRoot.FolderErrorText("ENOENTX", false).Title);
        Assert.Equal(new WorkspaceRoot.Words("Can’t Open This Folder", "The computer running Hermes doesn’t allow Hermes HQ to read this folder."),
            WorkspaceRoot.FolderErrorText("EACCES", false));
        Assert.Equal("Not a Folder", WorkspaceRoot.FolderErrorText("ENOTDIR", false).Title);
        Assert.Equal("The computer running Hermes did not say why.", WorkspaceRoot.FolderErrorText(" ", false).Body);
        Assert.Equal("Showing the first 512 KB of 2.5 MB.", WorkspaceRoot.TruncatedNotice(2_621_440));
        Assert.Equal("Showing the first 512 KB of 3 MB.", WorkspaceRoot.TruncatedNotice(3 << 20));
        Assert.Equal("Showing the first 512 KB.", WorkspaceRoot.TruncatedNotice(null));
        Assert.Equal("640 KB", WorkspaceRoot.FileSize(640 * 1024));
        Assert.True(WorkspaceRoot.IsNotGit("fatal: not a git repository (or any parent)"));
    }

    [Fact]
    public void ChangeWords()
    {
        Assert.Equal("+12 −3", WorkspaceRoot.Counts(12, 3));
        Assert.Equal("+5", WorkspaceRoot.Counts(5, 0));
        Assert.Equal("−4", WorkspaceRoot.Counts(0, 4));
        Assert.Equal("+0", WorkspaceRoot.Counts(0, 0));
        Assert.Equal("Binary", WorkspaceRoot.LinesWord(0, 0, "M", "assets/logo.bin"));
        Assert.Equal("", WorkspaceRoot.LinesWord(0, 0, "R", "a.txt"));
        Assert.Equal("—", WorkspaceRoot.LinesWord(0, 0, "M", "run.sh"));
        Assert.Null(WorkspaceRoot.LinesWord(1, 0, "M", "x.bin"));
        Assert.Equal("M", WorkspaceRoot.StatusLetter("zz"));
        Assert.Equal("?", WorkspaceRoot.StatusLetter(" ? "));
        Assert.Equal("New file", new WorkspaceChange("a", 1, 0, "?", false).StatusName);
        Assert.Equal("Changed", new WorkspaceChange("a", 1, 0, "M", false).StatusName);
        Assert.Equal(WorkspaceRoot.ChangeTint.Added, WorkspaceRoot.Tint("A"));
        Assert.Equal(WorkspaceRoot.ChangeTint.Deleted, WorkspaceRoot.Tint("D"));
        Assert.Equal("1 changed file", WorkspaceRoot.ChangeCount(1));
        Assert.Equal("11 items", WorkspaceRoot.ItemCount(11));
        Assert.Equal("/repo/src/a.js", WorkspaceRoot.FullPath(new("src/a.js", 1, 0, "M", false), "/repo", "/repo/src"));
        Assert.Equal("/dir/src/a.js", WorkspaceRoot.FullPath(new("src/a.js", 1, 0, "M", false), null, "/dir"));
    }

    [Fact]
    public void OpeningAndKinds()
    {
        Assert.Equal(WorkspaceRoot.OpeningKind.Text, WorkspaceRoot.Opening("Makefile"));
        Assert.Equal(WorkspaceRoot.OpeningKind.Text, WorkspaceRoot.Opening(".gitignore"));
        Assert.Equal(WorkspaceRoot.OpeningKind.Text, WorkspaceRoot.Opening("src/index.html"));
        Assert.Equal(WorkspaceRoot.OpeningKind.Download, WorkspaceRoot.Opening("photo.png"));
        Assert.True(WorkspaceRoot.IsMarkdown("README.md"));
        Assert.Equal("Folder", WorkspaceRoot.KindWord("src", true));
        Assert.Equal("Log File", WorkspaceRoot.KindWord("build.log", false));
        Assert.Equal("SQL", WorkspaceRoot.KindWord("huge.sql", false));
        Assert.Equal("Document", WorkspaceRoot.KindWord("Makefile", false));
        Assert.Equal("JSON", WorkspaceRoot.KindWord("package.json", false));
        Assert.Equal("Markdown", WorkspaceRoot.KindWord("README.md", false));
        Assert.Equal("Text", WorkspaceRoot.KindWord("notes.txt", false));
        Assert.Equal("Environment File", WorkspaceRoot.KindWord(".env.local", false));
        Assert.Equal("QuickTime Movie", WorkspaceRoot.KindWord("reel.mov", false));
    }

    [Fact]
    public void ListingsSortAndDedupe()
    {
        var sorted = ChatWorkspace.Sorted([new("file10", "/f10", false), new("b", "/b", true), new("File2", "/f2", false), new("a", "/a", true)]);
        Assert.Equal(["a", "b", "File2", "file10"], sorted.Select(e => e.Name));
        Assert.Single(WorkspaceRoot.Deduped([new WorkspaceEntry("a", "/a", false), new WorkspaceEntry("a", "/a", false)]));
        Assert.Equal(2, WorkspaceRoot.Deduped([new WorkspaceChange("a", 1, 0, "M", true), new WorkspaceChange("a", 1, 0, "M", false)]).Count);
        Assert.True(ChatWorkspace.Excluded("web/node_modules/x.js"));
        Assert.False(ChatWorkspace.Excluded("src/builder.js"));
    }

    [Fact]
    public void ChatFolderRecordFollowsTheLiveChat()
    {
        var prefs = new Prefs();
        new ChatFolderRecord("default", "s1", null, "Trip").Write(prefs, "acct");
        var saved = ChatFolderRecord.Read(prefs, "acct")!;
        Assert.Null(saved.FolderFor("default"));
        Assert.Equal("/rows/cwd", saved.FolderFor("", new Dictionary<string, string?> { ["s1"] = "/rows/cwd/" }));
        var merged = ChatFolderRecord.Merge(saved, new("default", "s1", "/home/x", "Trip"));
        Assert.Equal("/home/x", merged.FolderFor("default"));
        Assert.Null(merged.FolderFor("ivy"));
        // Another chat of the same bot without a folder keeps the saved one's folder but takes its title.
        Assert.Equal(saved with { Title = "New" }, ChatFolderRecord.Merge(saved with { SessionId = null }, new("default", "s2", null, "New")) with { SessionId = "s1" });
    }

    private static (WorkspaceVisit Visit, Rest Lane, Prefs Store) Visit(WorkspaceVisit.Kind kind, ChatFolderRecord? chat = null, string? defaultCwd = "/home/hermes/site")
    {
        var rest = new Rest();
        rest.Routes["/api/fs/default-cwd"] = _ => (200, new JsonObject { ["cwd"] = defaultCwd }.ToJsonString());
        rest.Routes["/api/profiles"] = _ => (200, """{"profiles":[{"name":"default","path":"/home/hermes/.hermes","is_default":true}]}""");
        rest.Routes["/api/fs/list"] = q => q["path"] switch
        {
            "/home/hermes/site" => (200, """{"entries":[{"name":"src","path":"/home/hermes/site/src","isDirectory":true},{"name":"README.md","path":"/home/hermes/site/README.md","isDirectory":false},{"name":"README.md","path":"/home/hermes/site/README.md"}]}"""),
            "/home/hermes/empty" => (200, """{"entries":[]}"""),
            "/home/hermes/gone" => (200, """{"entries":[],"error":"ENOENT"}"""),
            _ => (200, """{"entries":[],"error":"EACCES"}"""),
        };
        rest.Routes["/api/git/review/list"] = q => q["path"] == "/home/hermes/site"
            ? (200, """{"files":[{"path":"src/app.js","added":3,"removed":1,"status":"M","staged":false},{"path":"node_modules/x.js","added":1,"removed":0,"status":"M"}]}""")
            : (200, """{"files":[]}""");
        rest.Routes["/api/fs/git-root"] = q => (200, new JsonObject { ["root"] = q["path"].StartsWith("/home/hermes/site") ? "/home/hermes/site" : null }.ToJsonString());
        rest.Routes["/api/git/review/diff"] = q => (200, new JsonObject { ["diff"] = q["file"] == "src/app.js" ? "--- a\n+++ b\n+x" : "" }.ToJsonString());
        var prefs = new Prefs();
        return (new WorkspaceVisit(rest, prefs, "acct", kind, [B("default", true), B("ivy")], () => chat), rest, prefs);
    }

    [Fact]
    public async Task FilesListsTheGatewaysDefaultFolder()
    {
        var (visit, rest, _) = Visit(WorkspaceVisit.Kind.Files);
        await visit.AskHomeAsync();
        var (content, dir) = await WorkspaceListing.LoadRootAsync(visit, null);
        Assert.Equal("/home/hermes/site", dir);
        Assert.Equal(WorkspaceRoot.Source.Gateway, visit.Root!.Source);
        var rows = Assert.IsType<ListingContent.Entries>(content).Rows;
        Assert.Equal(["src", "README.md"], rows.Select(r => r.Name));
        Assert.Equal("~/site", visit.Display(dir!));
        Assert.DoesNotContain(rest.Asked, a => a.Contains("profile="));   // the default bot is never named

        // Another bot: its reads carry `profile`, its choice is kept.
        visit.SetProfile("ivy");
        await WorkspaceListing.LoadRootAsync(visit, null);
        Assert.Contains(rest.Asked, a => a.StartsWith("/api/fs/list?path=/home/hermes/site&profile=ivy"));
        Assert.Equal("ivy", WorkspaceVisit.ReadBot(new Prefs { Values = { [WorkspaceVisit.BotKey("acct")] = "ivy" } }, "acct", visit.Bots));
    }

    [Fact]
    public async Task TheChatsFolderComesBeforeTheGateways()
    {
        var (visit, rest, _) = Visit(WorkspaceVisit.Kind.Files, new ChatFolderRecord("default", "s1", "/home/hermes/empty", "Trip"));
        var (content, _) = await WorkspaceListing.LoadRootAsync(visit, null);
        Assert.Equal(WorkspaceRoot.EmptyFolder, Assert.IsType<ListingContent.State>(content).Words);
        Assert.Equal("The folder of “Trip”", WorkspaceRoot.SourceLine(visit.Root!.Source, visit.ChatTitle));
        Assert.DoesNotContain(rest.Asked, a => a.StartsWith("/api/fs/default-cwd"));
        // A folder that went away: the chat's words, with Try Again and Choose Folder….
        var (visit2, _, _) = Visit(WorkspaceVisit.Kind.Files, new ChatFolderRecord("default", "s1", "/home/hermes/gone", null));
        var gone = Assert.IsType<ListingContent.State>((await WorkspaceListing.LoadRootAsync(visit2, null)).Content);
        Assert.Equal("This chat’s folder no longer exists on the computer running Hermes.", gone.Words.Body);
        Assert.True(gone.Retry && gone.Choose);
        // The chosen folder wins over both.
        visit2.SetChosen("/home/hermes/site");
        Assert.IsType<ListingContent.Entries>((await WorkspaceListing.LoadRootAsync(visit2, null)).Content);
        Assert.Equal(WorkspaceRoot.Source.Chosen, visit2.Root!.Source);
    }

    [Fact]
    public async Task ChangesListsAndDiffs()
    {
        var (visit, _, _) = Visit(WorkspaceVisit.Kind.Review);
        var changes = Assert.IsType<ListingContent.Changes>((await WorkspaceListing.LoadRootAsync(visit, null)).Content);
        var change = Assert.Single(changes.Rows);
        Assert.Equal("/home/hermes/site", changes.RepoRoot);
        Assert.Contains("+x", await visit.Workspace.DiffAsync("/home/hermes/site", change));
        // Not a repository, and no gateway folder at all.
        var (notGit, _, _) = Visit(WorkspaceVisit.Kind.Review, defaultCwd: "/home/hermes/notes");
        Assert.Equal(WorkspaceRoot.NotGit, Assert.IsType<ListingContent.State>((await WorkspaceListing.LoadRootAsync(notGit, null)).Content).Words);
        var (none, _, _) = Visit(WorkspaceVisit.Kind.Review, defaultCwd: null);
        var noFolder = Assert.IsType<ListingContent.State>((await WorkspaceListing.LoadRootAsync(none, null)).Content);
        Assert.Equal("No Folder Yet", noFolder.Words.Title);
        Assert.True(noFolder.Choose);
    }

    [Fact]
    public async Task AnOlderHermesSaysNotAvailable()
    {
        var (visit, rest, _) = Visit(WorkspaceVisit.Kind.Review);
        rest.Routes.Remove("/api/fs/default-cwd");
        var state = Assert.IsType<ListingContent.State>((await WorkspaceListing.LoadRootAsync(visit, null)).Content);
        Assert.Equal("Not Available on This Hermes", state.Words.Title);
        Assert.Equal("This Hermes doesn’t have Changes. Updating Hermes may add it.", state.Words.Body);
        Assert.False(state.Retry);
    }

    [Fact]
    public async Task TheChooserListsFoldersOnly()
    {
        var (visit, _, _) = Visit(WorkspaceVisit.Kind.Files);
        var rows = Assert.IsType<ListingContent.Entries>(await WorkspaceListing.ReadAsync(visit, "/home/hermes/site", isRoot: false, chooser: true)).Rows;
        Assert.Equal(["src"], rows.Select(r => r.Name));
        // An empty folder in the chooser is a list with no rows ("No folders here"), not a state.
        Assert.Empty(Assert.IsType<ListingContent.Entries>(await WorkspaceListing.ReadAsync(visit, "/home/hermes/empty", false, true)).Rows);
    }

    [Fact]
    public async Task ATextReadPastTheLimitIsTooLarge()
    {
        var (visit, rest, _) = Visit(WorkspaceVisit.Kind.Files);
        rest.Routes["/api/fs/read-text"] = _ => (413, """{"detail":"File too large"}""");
        await Assert.ThrowsAsync<ChatWorkspace.TooLargeException>(() => visit.Workspace.ReadTextAsync("/home/hermes/site/huge.sql"));
        rest.Routes["/api/fs/read-text"] = _ => (200, """{"path":"/x","text":"abc","truncated":true,"byteSize":3000000}""");
        var file = await visit.Workspace.ReadTextAsync("/x");
        Assert.True(file.Truncated);
        Assert.Equal(3000000, file.ByteSize);
        Assert.Equal("The gateway couldn’t do that.", ChatWorkspace.Reason(new InvalidOperationException()));
        Assert.Equal("Nope", ChatWorkspace.Reason(new GatewayException("http", "Nope", 500)));
    }
}
