using System.Text;
using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Composer;
using Hermes.Core.Net;
using Hermes.Core.Terminal;
using Hermes.Core.Workspace;

namespace Hermes.Core.Tests;

/// Files, Changes and the Terminal against windows/ci/fixtures/workspace-gateway.py (the invented tree of
/// scripts/fixtures/morepages/workspace.py and a stand-in shell behind the add-on's socket). Run through
/// windows/scripts/e2e.sh (HQW_E2E_WORKSPACE_CREDENTIALS); without it these pass vacuously.
[Trait("Category", "E2E")]
public class WorkspaceEndToEndTests
{
    private static async Task Until(Func<bool> condition, int seconds = 20)
    {
        var until = DateTime.UtcNow.AddSeconds(seconds);
        while (!condition())
        {
            if (DateTime.UtcNow > until) throw new TimeoutException("condition not met");
            await Task.Delay(50);
        }
    }

    private static async Task<JsonNode> Post(string url, string path, object body)
    {
        using var http = new HttpClient();
        var r = await http.PostAsync(url.TrimEnd('/') + path,
            new StringContent(System.Text.Json.JsonSerializer.Serialize(body), Encoding.UTF8, "application/json"));
        r.EnsureSuccessStatusCode();
        return JsonNode.Parse(await r.Content.ReadAsStringAsync())!;
    }

    private static async Task<JsonNode> Get(string url, string path)
    {
        using var http = new HttpClient();
        return JsonNode.Parse(await http.GetStringAsync(url.TrimEnd('/') + path))!;
    }

    private static async Task<(GatewaySession Session, string Url)?> SignInAsync()
    {
        var path = Environment.GetEnvironmentVariable("HQW_E2E_WORKSPACE_CREDENTIALS");
        if (path == null || !File.Exists(path)) return null;
        var cred = JsonNode.Parse(File.ReadAllText(path))!;
        var url = cred.Str("url")!;
        var session = await new SignIn(new MemoryTokenStore()).PasswordAsync(GatewayAddress.FromTyped(url), cred.Str("username")!, cred.Str("password")!);
        return (session, url);
    }

    [Fact]
    public async Task FilesAndChangesReadTheGatewaysFolders()
    {
        if (await SignInAsync() is not var (session, url)) return;
        using var _ = session;
        await Post(url, "/__fixture/workspace", new { reset = true });
        var rest = new SessionWorkspaceRest(session);
        var prefs = new WorkspaceTests.Prefs();
        var bots = new List<Model.Bot> { new("default", "Hermes", null, null, true, false, false, null, false, null, null) };

        // Files: the gateway's default folder, its rows as the Mac's table lists them, "~" for the home.
        var files = new WorkspaceVisit(rest, prefs, session.Account.Key, WorkspaceVisit.Kind.Files, bots, () => null);
        await files.AskHomeAsync();
        var (content, dir) = await WorkspaceListing.LoadRootAsync(files, null);
        Assert.Equal("/home/hermes/projects/site", dir);
        Assert.Equal("~/projects/site", files.Display(dir!));
        var rows = Assert.IsType<ListingContent.Entries>(content).Rows;
        Assert.Equal(["assets", "empty", "private", "src", "build.log", "huge.sql", "Makefile", "package.json", "README.md", "שלום 👋 notes.txt"],
            rows.Select(r => r.Name));
        Assert.Equal(["Folder", "Log File", "SQL", "Document", "JSON", "Markdown", "Text"],
            rows.Select(r => WorkspaceRoot.KindWord(r.Name, r.IsDirectory)).Distinct());

        // A folder opened in place, an empty one, one that refuses, the trail.
        var src = Assert.IsType<ListingContent.Entries>((await WorkspaceListing.LoadRootAsync(files, dir + "/src")).Content).Rows;
        Assert.Equal(["components", "app.js", "index.html"], src.Select(r => r.Name));
        Assert.Equal(["site", "src"], WorkspaceRoot.Crumbs(dir!, dir + "/src").Select(c => c.Name));
        Assert.Equal(WorkspaceRoot.EmptyFolder, Assert.IsType<ListingContent.State>((await WorkspaceListing.LoadRootAsync(files, dir + "/empty")).Content).Words);
        var refused = Assert.IsType<ListingContent.State>((await WorkspaceListing.LoadRootAsync(files, dir + "/private")).Content);
        Assert.Equal("Can’t Open This Folder", refused.Words.Title);

        // Text, a long file cut short, one too large to read as text (then fetched whole), bytes.
        var readme = await files.Workspace.ReadTextAsync(dir + "/README.md");
        Assert.StartsWith("# Site", readme.Text);
        var log = await files.Workspace.ReadTextAsync(dir + "/build.log");
        Assert.True(log.Truncated);
        Assert.Equal("Showing the first 512 KB of 3 MB.", WorkspaceRoot.TruncatedNotice(log.ByteSize));
        await Assert.ThrowsAsync<ChatWorkspace.TooLargeException>(() => files.Workspace.ReadTextAsync(dir + "/huge.sql"));
        var temp = Path.Combine(Path.GetTempPath(), "hqw-e2e-" + Guid.NewGuid().ToString("n"), "logo.bin");
        await files.Workspace.DownloadAsync(dir + "/assets/logo.bin", temp);
        Assert.Equal(2048, new FileInfo(temp).Length);
        Directory.Delete(Path.GetDirectoryName(temp)!, true);

        // The chooser, then a chosen folder.
        var chooser = Assert.IsType<ListingContent.Entries>(await WorkspaceListing.ReadAsync(files, "/home/hermes/projects", false, true)).Rows;
        Assert.Equal(["notes", "site"], chooser.Select(r => r.Name));
        files.SetChosen("/home/hermes/projects/notes");
        Assert.Equal(["ideas.md", "todo.txt"], Assert.IsType<ListingContent.Entries>((await WorkspaceListing.LoadRootAsync(files, null)).Content).Rows.Select(r => r.Name));
        Assert.Equal("Folder you chose", WorkspaceRoot.SourceLine(files.Root!.Source, files.ChatTitle));

        // Changes: the repository's changes and a diff; a folder that isn't one.
        var review = new WorkspaceVisit(rest, new WorkspaceTests.Prefs(), session.Account.Key, WorkspaceVisit.Kind.Review, bots, () => null);
        var changes = Assert.IsType<ListingContent.Changes>((await WorkspaceListing.LoadRootAsync(review, null)).Content);
        Assert.Equal(["src/app.js", "src/pricing.html", "assets/logo.bin"], changes.Rows.Select(c => c.Path));
        Assert.Equal("/home/hermes/projects/site", changes.RepoRoot);
        Assert.Equal("Binary", WorkspaceRoot.LinesWord(0, 0, "M", "assets/logo.bin"));
        Assert.Contains("+footer(document.body)", await review.Workspace.DiffAsync("/home/hermes/projects/site", changes.Rows[0]));
        await Post(url, "/__fixture/workspace", new { default_cwd = "/home/hermes/projects/notes" });
        Assert.Equal(WorkspaceRoot.NotGit, Assert.IsType<ListingContent.State>((await WorkspaceListing.LoadRootAsync(review, null)).Content).Words);
        // The chat's own folder comes before the gateway's: a clean repository.
        var chat = new WorkspaceVisit(rest, new WorkspaceTests.Prefs(), session.Account.Key, WorkspaceVisit.Kind.Review, bots,
            () => new ChatFolderRecord("default", "s1", "/home/hermes/app", "Release"));
        Assert.Equal(WorkspaceRoot.NoChanges, Assert.IsType<ListingContent.State>((await WorkspaceListing.LoadRootAsync(chat, null)).Content).Words);
        await Post(url, "/__fixture/workspace", new { reset = true });
    }

    private sealed class Tab
    {
        public readonly TerminalScreen Screen = new(80, 24);
        public TerminalConnection Connection = null!;
        public string Text { get { lock (Screen) return Screen.AllText(); } }
    }

    private static Tab Open(GatewaySession session, string id)
    {
        var tab = new Tab();
        var dial = TerminalDialer.For(session);
        tab.Connection = new TerminalConnection(id, (q, ct) => dial(q, ct));
        tab.Connection.Output += b => { lock (tab.Screen) tab.Screen.Feed(b); };
        tab.Connection.Reset += () => { lock (tab.Screen) tab.Screen.Clear(); };
        tab.Connection.Start(80, 24);
        return tab;
    }

    [Fact]
    public async Task TheTerminalTypesComesBackAndEnds()
    {
        if (await SignInAsync() is not var (session, url)) return;
        using var _ = session;
        await Post(url, "/__fixture/terminal", new { reset = true });

        // The add-on says it has the Terminal.
        var status = await session.SendAsync(HttpMethod.Get, TerminalWire.Route + "/status");
        Assert.Equal(TerminalWire.AddOn.Ready, TerminalWire.AddOnFrom(status.Status, status.Json));

        var id = TerminalWire.NewSession();
        var tab = Open(session, id);
        await Until(() => tab.Connection.CurrentPhase is TerminalConnection.Phase.Live);
        await Until(() => tab.Text.EndsWith("\n$"));
        Assert.Contains("Hermes HQ  red green yellow blue", tab.Text);
        tab.Connection.Send(Encoding.UTF8.GetBytes("echo hello from windows\r"));
        await Until(() => tab.Text.Contains("hello from windows\n$"));
        tab.Connection.Resize(100, 30);
        await Until(() => (Get(url, "/__fixture/terminal").Result.Arr("sessions")![0]!).Int("cols") == 100);
        // A paste with bracketed paste's marks, and the shell's title.
        tab.Connection.Send(TerminalKeys.Paste("title build\n", bracketed: true));
        await Until(() => tab.Screen.Title == "build");

        // Leave and come back: the same shell, only what was missed, nothing twice.
        var shown = tab.Connection.Shown;
        tab.Connection.Stop();
        var back = Open(session, id);
        await Until(() => back.Connection.CurrentPhase is TerminalConnection.Phase.Live);
        await Until(() => back.Connection.Shown >= shown);
        back.Connection.Send(Encoding.UTF8.GetBytes("pwd\r"));
        await Until(() => back.Text.Contains("/home/hermes"));
        Assert.Equal(1, back.Text.Split("\nhello from windows\n").Length - 1);

        // The same shell opened again elsewhere takes it: the first stops, as Open in Another Window.
        var other = Open(session, id);
        await Until(() => back.Connection.CurrentPhase is TerminalConnection.Phase.Stopped);
        Assert.Equal(TerminalWire.EndingKind.Replaced, ((TerminalConnection.Phase.Stopped)back.Connection.CurrentPhase).Ending.Kind);
        await Until(() => other.Connection.CurrentPhase is TerminalConnection.Phase.Live);

        // End Shell: "You ended this shell."
        other.Connection.EndShell();
        await Until(() => other.Connection.CurrentPhase is TerminalConnection.Phase.Ended);
        other.Connection.Stop();

        // A shell that exits by itself says its code.
        var second = Open(session, TerminalWire.NewSession());
        await Until(() => second.Connection.CurrentPhase is TerminalConnection.Phase.Live);
        second.Connection.Send(Encoding.UTF8.GetBytes("exit 3\r"));
        await Until(() => second.Connection.CurrentPhase is TerminalConnection.Phase.Ended);
        Assert.Equal("It exited with code 3.", TerminalWords.Ended(((TerminalConnection.Phase.Ended)second.Connection.CurrentPhase).Code, false).Body);
        second.Connection.Stop();
    }

    [Fact]
    public async Task TheTerminalSaysWhyItCantOpen()
    {
        if (await SignInAsync() is not var (session, url)) return;
        using var _ = session;
        async Task<TerminalWire.EndingKind> Ending(object fixture)
        {
            await Post(url, "/__fixture/terminal", new { reset = true });
            await Post(url, "/__fixture/terminal", fixture);
            var tab = Open(session, TerminalWire.NewSession());
            try
            {
                await Until(() => tab.Connection.CurrentPhase is TerminalConnection.Phase.Stopped);
                return ((TerminalConnection.Phase.Stopped)tab.Connection.CurrentPhase).Ending.Kind;
            }
            finally { tab.Connection.Stop(); }
        }
        Assert.Equal(TerminalWire.EndingKind.Off, await Ending(new { off = true }));
        Assert.Equal(TerminalWire.EndingKind.Unsupported, await Ending(new { supported = false }));
        Assert.Equal(TerminalWire.EndingKind.Full, await Ending(new { full = true }));
        Assert.Equal(TerminalWire.EndingKind.Blocked, await Ending(new { blocked = true }));

        // An add-on from before the Terminal, and none at all.
        await Post(url, "/__fixture/terminal", new { reset = true, plugin = "outdated" });
        var old = await session.SendAsync(HttpMethod.Get, TerminalWire.Route + "/status");
        Assert.Equal(TerminalWire.AddOn.NeedsUpdate, TerminalWire.AddOnFrom(old.Status, old.Json));
        await Post(url, "/__fixture/terminal", new { plugin = "missing" });
        var none = await session.SendAsync(HttpMethod.Get, TerminalWire.Route + "/status");
        Assert.Equal(TerminalWire.AddOn.NeedsUpdate, TerminalWire.AddOnFrom(none.Status, none.Json));
        await Post(url, "/__fixture/terminal", new { reset = true });
    }
}
