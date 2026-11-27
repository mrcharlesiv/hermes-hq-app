// [WIN-LOST-SEND-MARKER] Sends that may never have arrived, kept for the Sessions row (93f984bb1
// Tests/Sessions/LostSendsTests.swift, case for case: notesClearsAndTellsTheRows, countsAnAccountsEntries,
// aDeletedChatsEntriesGo, survivesARelaunchAndIsPurgedWithTheAccount, boundsAndBadFiles), and the row's pending line
// (SessionRowWordsTests.swift pendingLine, detailText's pending cases and voiceOverLabel's lost line;
// SessionStoreViewTests.swift statusFollowsItsInputs' pending half). Synthetic data, a temporary folder each.

using Hermes.Core.Bots;
using Hermes.Core.Net;
using Hermes.Core.Sessions;

namespace Hermes.Core.Tests;

public sealed class LostSendsTests : IDisposable
{
    private readonly List<string> _folders = [];

    private string Folder()
    {
        var dir = Directory.CreateTempSubdirectory("lost-sends-test-").FullName;
        _folders.Add(dir);
        return dir;
    }

    public void Dispose()
    {
        foreach (var dir in _folders) try { Directory.Delete(dir, true); } catch (IOException) { }
    }

    private static LostSends.Entry E(string id, string text, double at = 1_791_000_000) =>
        new(id, text, DateTimeOffset.FromUnixTimeMilliseconds((long)(at * 1000)));

    [Fact]
    public void NotesClearsAndTellsTheRows()
    {
        var store = new LostSends(Folder());
        var changes = 0;
        store.Changed += () => changes++;
        store.Note("acct", "default", "s1", E("local-1", "  send the quote  "));
        store.Note("acct", "default", "s1", E("local-2", "second"));
        store.Note("acct", "research", "s1", E("local-1", "the twin's"));   // a twin chat is its own
        Assert.Equal("send the quote", store.First("acct", "default", "s1")?.Text);
        Assert.Equal(["local-1", "local-2"], store.Entries("acct", "default", "s1").Select(e => e.Id));
        Assert.Equal("the twin's", store.First("acct", "research", "s1")?.Text);
        Assert.Null(store.First("other", "default", "s1"));
        Assert.Equal(3, changes);
        // The same message marked again replaces its entry; blank words and a chat without an id are not kept.
        store.Note("acct", "default", "s1", E("local-1", "send the quote again"));
        Assert.Equal(["second", "send the quote again"], store.Entries("acct", "default", "s1").Select(e => e.Text));
        store.Note("acct", "default", "s1", E("local-3", " \n "));
        store.Note("acct", "default", "", E("local-4", "words"));
        Assert.Equal(2, store.Entries("acct", "default", "s1").Count);
        store.Clear("acct", "default", "s1", "local-2");
        store.Clear("acct", "default", "s1", "never-there");
        Assert.Equal(["local-1"], store.Entries("acct", "default", "s1").Select(e => e.Id));
        store.Rekey("acct", "default", "s1", "local-1", "local-user-lost-abc");
        Assert.Equal("local-user-lost-abc", store.First("acct", "default", "s1")?.Id);
        store.Clear("acct", "default", "s1", "local-user-lost-abc");
        Assert.Null(store.First("acct", "default", "s1"));
    }

    /// Sign Out and Remove count what they delete: every chat's entries, per account.
    [Fact]
    public void CountsAnAccountsEntries()
    {
        var store = new LostSends(Folder());
        Assert.Equal(0, store.Count("acct"));
        store.Note("acct", "default", "s1", E("local-1", "one"));
        store.Note("acct", "default", "s1", E("local-2", "two"));
        store.Note("acct", "research", "s2", E("local-3", "three"));
        store.Note("other", "default", "s1", E("local-4", "four"));
        Assert.Equal(3, store.Count("acct"));
        store.Purge("acct");
        Assert.Equal(0, store.Count("acct"));
    }

    /// Deleting a chat takes its entries (and only its), on disk too.
    [Fact]
    public void ADeletedChatsEntriesGo()
    {
        var folder = Folder();
        var store = new LostSends(folder);
        var changes = 0;
        store.Changed += () => changes++;
        store.Note("acct", "default", "s1", E("local-1", "one"));
        store.Note("acct", "default", "s1", E("local-2", "two"));
        store.Note("acct", "research", "s1", E("local-3", "the twin's"));
        store.Note("acct", "default", "s2", E("local-4", "another chat's"));
        changes = 0;
        store.Clear("acct", "default", "s1");
        Assert.Equal(1, changes);
        Assert.Empty(store.Entries("acct", "default", "s1"));
        Assert.Equal("the twin's", store.First("acct", "research", "s1")?.Text);
        Assert.Equal("another chat's", store.First("acct", "default", "s2")?.Text);
        store.Clear("acct", "default", "never");
        Assert.Equal(1, changes);   // nothing to clear, nothing said
        store.Flush();
        var again = new LostSends(folder);
        Assert.Empty(again.Entries("acct", "default", "s1"));
        Assert.Equal("another chat's", again.First("acct", "default", "s2")?.Text);
    }

    [Fact]
    public void SurvivesARelaunchAndIsPurgedWithTheAccount()
    {
        var folder = Folder();
        var store = new LostSends(folder);
        store.Note("acct", "default", "s1", E("local-1", "send the quote"));
        store.Note("acct-b", "default", "s9", E("local-1", "another account's"));
        store.Flush();
        Assert.True(File.Exists(LostSends.FilePath("acct", folder)));
        var again = new LostSends(folder);
        Assert.Equal(E("local-1", "send the quote"), again.First("acct", "default", "s1"));
        again.Purge("acct");
        again.Flush();
        Assert.Null(again.First("acct", "default", "s1"));
        Assert.False(File.Exists(LostSends.FilePath("acct", folder)));
        Assert.Equal("another account's", new LostSends(folder).First("acct-b", "default", "s9")?.Text);
        // The last entry cleared removes the file.
        var last = new LostSends(folder);
        last.Clear("acct-b", "default", "s9", "local-1");
        last.Flush();
        Assert.False(File.Exists(LostSends.FilePath("acct-b", folder)));
    }

    [Fact]
    public void BoundsAndBadFiles()
    {
        var folder = Folder();
        var store = new LostSends(folder);
        for (var i = 0; i < 30; i++) store.Note("acct", "p", "s", E($"m{i}", $"words {i}", i));
        store.Note("acct", "p", "s", E("long", new string('x', 5_000)));
        var kept = store.Entries("acct", "p", "s");
        Assert.Equal(LostSends.MaxEntries, kept.Count);
        Assert.Equal("m11", kept[0].Id);
        Assert.Equal(LostSends.MaxCharacters, kept[^1].Text.Length);
        // A torn or newer file reads as nothing, and the next change writes a good one.
        var file = LostSends.FilePath("torn", folder);
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        File.WriteAllText(file, "{\"v\":2,\"chats\":{\"p\\u001Fs\":");
        var torn = new LostSends(folder);
        Assert.Empty(torn.Entries("torn", "p", "s"));
        torn.Note("torn", "p", "s", E("m", "fresh"));
        torn.Flush();
        Assert.Equal(["fresh"], LostSends.Load("torn", folder)[LostSends.Key("p", "s")].Select(e => e.Text));
    }

    // ------------------------------------------------------------------ the row's pending line

    private static SessionSummary Chat(string title = "Garden plan", string? preview = "Water the beds",
        SessionStatus status = SessionStatus.Idle, SessionPending? pending = null) => new()
    {
        Id = "s", Profile = "default", Title = title, Preview = preview, Status = status, Pending = pending,
        Unread = status == SessionStatus.Unread, IsRunning = status == SessionStatus.Working,
    };

    [Fact]
    public void PendingLine()
    {
        Assert.Null(SessionPending.Pending(null, null));
        Assert.Null(SessionPending.Pending(null, "  \n"));
        Assert.Equal(new SessionPending(false, "call the plumber"), SessionPending.Pending(null, " call the plumber "));
        var both = SessionPending.Pending("send the quote", "call the plumber");
        Assert.Equal(new SessionPending(true, "send the quote"), both);   // a lost send wins over a draft
        Assert.Equal("Not Delivered:", both!.Prefix);
        Assert.Equal("Draft:", new SessionPending(false, "x").Prefix);
    }

    /// SessionRowWordsTests detailText: a live status wins over the pending line, which wins over the detail.
    [Fact]
    public void ALiveStatusWinsOverThePendingLineWhichWinsOverTheDetail()
    {
        var draft = new SessionPending(false, "call the plumber");
        HashSet<SessionRowDetail> preview = [SessionRowDetail.Preview];
        Assert.Equal("Draft: call the plumber", SessionRowWords.DetailText(Chat(status: SessionStatus.Draft, pending: draft), preview));
        Assert.Equal("Working…", SessionRowWords.DetailText(Chat(status: SessionStatus.Working, pending: draft), preview));
        Assert.Equal("Needs your input", SessionRowWords.DetailText(Chat(status: SessionStatus.NeedsInput, pending: draft), preview));
        Assert.Equal("Not Delivered: send the quote",
            SessionRowWords.DetailText(Chat(pending: new SessionPending(true, "send the quote")), preview));
    }

    /// SessionRowWordsTests voiceOverLabel's lost line: the row's automation name says it too.
    [Fact]
    public void TheRowsNameSaysNotDelivered()
    {
        var lost = Chat(pending: new SessionPending(true, "send the quote"));
        Assert.Equal("T. Hermes: Not Delivered: send the quote",
            SessionRowWords.AccessibilityLabel("T", lost, "Hermes", new HashSet<SessionRowDetail> { SessionRowDetail.Preview }, "Now"));
    }

    /// SessionStoreViewTests statusFollowsItsInputs, its pending half: a draft is Draft; a lost send keeps the chat's own
    /// status (here Unread) and leads its line. (Windows' rows are read as they are drawn, so RefreshPending only tells
    /// the list to draw again; the Mac's "not read again until told" step has no Windows counterpart.)
    [Fact]
    public async Task StatusFollowsThePendingLine()
    {
        var gw = new FakeGateway();
        gw.OnRest = (m, p, _, _) => (m, p) switch
        {
            ("GET", "/api/profiles/sessions/sidebar") => new RestAnswer(200, """{"recents":{"sessions":[{"id":"new","profile":"ivy","title":"N","unread":true,"last_active":30},{"id":"typed","profile":"ivy","title":"T","last_active":20},{"id":"quiet","profile":"ivy","title":"Q","last_active":10}]},"cron":{"sessions":[]},"messaging":{"sessions":[]}}"""),
            ("GET", _) => new RestAnswer(404, ""),
            _ => new RestAnswer(200, "{}"),
        };
        var store = new SessionStore(gw, new MemoryDeviceStore());
        await store.RefreshAsync();
        var pending = new Dictionary<string, SessionPending>();
        store.PendingLine = (_, id) => pending.GetValueOrDefault(id);
        var told = 0;
        store.Changed += () => told++;
        SessionSummary Row(string id) => store.LiveSummaries().First(s => s.Id == id);
        Assert.Equal(SessionStatus.Idle, Row("typed").Status);
        pending["typed"] = new SessionPending(false, "half a thought");
        pending["new"] = new SessionPending(true, "lost words");
        store.RefreshPending();
        Assert.Equal(1, told);
        Assert.Equal(SessionStatus.Draft, Row("typed").Status);
        Assert.Equal("Draft:", Row("typed").Pending?.Prefix);
        Assert.Equal(SessionStatus.Unread, Row("new").Status);
        Assert.Equal("Not Delivered:", Row("new").Pending?.Prefix);
        Assert.Equal(SessionStatus.Idle, Row("quiet").Status);
        Assert.Null(Row("quiet").Pending);
        // A lost send alone (nothing unread) is not a draft: the chat stays Idle, its line says Not Delivered.
        pending["quiet"] = new SessionPending(true, "call the plumber");
        Assert.Equal(SessionStatus.Idle, Row("quiet").Status);
    }

    /// AppModel's `sessions.onDeleted`: deleting a chat on the gateway says so, and the app clears its lost sends.
    [Fact]
    public async Task DeletingAChatSaysSo()
    {
        var gw = new FakeGateway();
        gw.OnRest = (m, p, _, _) => (m, p) switch
        {
            ("GET", "/api/profiles/sessions/sidebar") => new RestAnswer(200, """{"recents":{"sessions":[{"id":"gone","profile":"ivy","title":"G","last_active":30}]},"cron":{"sessions":[]},"messaging":{"sessions":[]}}"""),
            ("GET", _) => new RestAnswer(404, ""),
            _ => new RestAnswer(200, "{}"),
        };
        var store = new SessionStore(gw, new MemoryDeviceStore());
        await store.RefreshAsync();
        var lost = new LostSends(Folder());
        lost.Note("acct", "ivy", "gone", E("local-1", "words"));
        store.Deleted += (profile, id) => lost.Clear("acct", profile, id);
        await store.DeleteAsync(store.LiveSummaries().Single());
        Assert.Null(lost.First("acct", "ivy", "gone"));
    }
}
