using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Gateways;
using Hermes.Core.Model;
using Hermes.Core.Net;

namespace Hermes.Core.Tests;

/// Gateway naming, the version check, news, sign-out words and the saved list (Tests/Settings/SettingsModelTests.swift
/// `GatewayNamingTests`, Tests/Onboarding/*).
public class GatewayNamingTests
{
    private static Uri? U(string s) => Uri.TryCreate(s, UriKind.Absolute, out var u) ? u : null;

    [Theory]
    [InlineData("http://100.101.102.103:9119", "Your Gateway")]
    [InlineData("http://127.0.0.1:9241", "Your Gateway")]
    [InlineData("http://[::1]:9119", "Your Gateway")]
    [InlineData("http://localhost:9119", "Your Gateway")]
    [InlineData("https://mac-mini.tail1234.ts.net", "Mac mini")]
    [InlineData("http://alexs-Mac-Studio.local:9119", "Alex’s Mac Studio")]
    [InlineData("http://alexs-macbook-pro.local:9119", "Alex’s MacBook Pro")]
    [InlineData("", "Your Gateway")]
    [InlineData("not a url", "Your Gateway")]
    public void NamesTheGatewayByItsComputer(string url, string expected) =>
        Assert.Equal(expected, GatewayNaming.FriendlyName(U(url)));

    [Fact]
    public void PutsTheAddressOnItsOwnLine()
    {
        Assert.Equal("100.101.102.103:9119", GatewayNaming.Host(U("http://100.101.102.103:9119/"), port: true));
        Assert.Equal("gw.example.com", GatewayNaming.Host(U("https://gw.example.com/path"), port: true));
        Assert.Equal("[::1]:9119", GatewayNaming.Host(U("http://[::1]:9119"), port: true));
        Assert.Equal("", GatewayNaming.Host(null, port: true));
    }

    [Fact]
    public void RowsNameEachGatewayWithWhoIsSignedIn()
    {
        var a = GatewayNaming.Row(U("https://office-mac.tail1234.ts.net")!, null, "owner", true);
        Assert.Equal(("Office Mac", "office-mac.tail1234.ts.net · owner"), a);
        var b = GatewayNaming.Row(U("http://100.101.102.103:9400")!, null, "qa", false);
        Assert.Equal(("100.101.102.103:9400", "qa · Signed Out"), b);
        var named = GatewayNaming.Row(U("http://100.101.102.103:9400")!, "Work Server", "qa", true);
        Assert.Equal(("Work Server", "100.101.102.103:9400 · qa"), named);
        Assert.Equal("100.101.102.103:9400", GatewayNaming.Row(U("http://100.101.102.103:9400")!, "  ", "qa", true).Title);
        Assert.Equal("Nous account", GatewayNaming.AccountName("nous:user-1"));
        Assert.Equal("qa", GatewayNaming.AccountName("qa"));
    }

    [Fact]
    public void ALoopbackGatewayIsThisComputer()
    {
        GatewayNaming.ThisComputer = "STUDIO-PC";
        try
        {
            Assert.Equal("STUDIO-PC", GatewayNaming.FriendlyName(U("http://127.0.0.1:9119")));
            Assert.Equal("Mac mini", GatewayNaming.FriendlyName(U("https://mac-mini.tail1234.ts.net")));
        }
        finally { GatewayNaming.ThisComputer = null; }
    }

    [Fact]
    public void SignOutAndRemoveSayWhatGoes()
    {
        Assert.Equal("its drafts", SignOutWords.Lost(0, 0));
        Assert.Equal("its drafts and 1 unsent message", SignOutWords.Lost(1, 0));
        Assert.Equal("its drafts, 2 unsent messages and 1 voice recording", SignOutWords.Lost(2, 1));
        var only = SignOutWords.SignOut("Home Mac", null);
        Assert.Equal("Sign out of Home Mac?", only.Title);
        Assert.Equal("Its drafts on this PC are deleted. Your bots and chats stay on Home Mac. You can sign in again any time.", only.Message);
        var two = SignOutWords.SignOut("Studio", "Mac Mini", 2, 3);
        Assert.Equal("Studio leaves this list and Hermes HQ switches to Mac Mini. Its drafts, 2 unsent messages and "
            + "3 voice recordings on this PC are deleted. Your bots and chats stay on Studio. You can sign in again any time.", two.Message);
        Assert.Equal("qa is signed out of this gateway on this PC, and its drafts here are deleted. You can add it again.",
            SignOutWords.Remove("qa"));
    }
}

public class GatewayCompatibilityTests
{
    private static JsonNode S(string json) => JsonNode.Parse(json)!;

    [Fact]
    public void OlderReleasesAreOutdatedNewerOnesAndGuessesAreNot()
    {
        var old = GatewayCompatibility.From(S("""{"version":" 0.21.5 ","release_date":"2026.9.10","can_update_hermes":true}"""));
        Assert.Equal(CompatibilityKind.Outdated, old.Kind);
        Assert.Equal(new OutdatedGateway("0.21.5", "2026.9.10", true), old.Outdated);
        Assert.Equal(CompatibilityKind.Compatible, GatewayCompatibility.From(S("""{"release_date":"2026.9.21"}""")).Kind);
        Assert.Equal(CompatibilityKind.Compatible, GatewayCompatibility.From(S("""{"release_date":"2026.10.01"}""")).Kind);
        // Anything that can't be read as an older release never blocks.
        foreach (var bad in new[] { "{}", """{"release_date":"2026-09-10"}""", """{"release_date":"26.9.10"}""",
                     """{"release_date":"2026.13.1"}""", """{"release_date":"2026.9.32"}""", """{"release_date":20260910}""",
                     """{"release_date":"2026.9.١"}""" })
            Assert.Equal(CompatibilityKind.Unknown, GatewayCompatibility.From(S(bad)).Kind);
        Assert.Equal(CompatibilityKind.Unknown, GatewayCompatibility.From(null).Kind);
        // can_update_hermes: only an explicit false says no; the version is cut at 24 characters and only text counts.
        var managed = GatewayCompatibility.From(S("""{"version":12,"release_date":"2026.1.2","can_update_hermes":false}""")).Outdated!;
        Assert.False(managed.CanUpdate);
        Assert.Equal("", managed.Version);
        var longVersion = GatewayCompatibility.From(S("""{"version":"0123456789012345678901234567","release_date":"2026.1.2"}""")).Outdated!;
        Assert.Equal(24, longVersion.Version.Length);
    }

    [Fact]
    public void TheUpdateScreenSaysWhatToDo()
    {
        Assert.Equal("Hermes 0.21.5 · released 2026.9.10", OutdatedCopy.Release(new OutdatedGateway("0.21.5", "2026.9.10")));
        Assert.Equal("Hermes · released 2026.9.10", OutdatedCopy.Release(new OutdatedGateway("", "2026.9.10")));
        Assert.EndsWith("On the computer running Hermes, run “hermes update”, then check again.", OutdatedCopy.Recovery(true));
        Assert.StartsWith("Hermes HQ needs a newer version of Hermes than the computer running Hermes has", OutdatedCopy.Recovery(false));
    }

    /// How long a test waits for evidence the cap's work produces. Only a ceiling for a broken build: a working one
    /// signals at once, so this never stretches a passing run.
    private static readonly TimeSpan Evidence = TimeSpan.FromSeconds(30);

    [Fact]
    public async Task TheCapTurnsASlowReadIntoUnknown()
    {
        // The read can only finish by being cancelled, so an Unknown answer can't come from it ending early, and the
        // signal below fires from the cancellation itself, whenever the pool gets to it, rather than being polled
        // after a guessed sleep.
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var cancelled = new TaskCompletionSource<CancellationToken>(TaskCreationOptions.RunContinuationsAsynchronously);
        var finishedOtherwise = false;
        CancellationToken given = default;
        var answer = await GatewayCompatibility.CappedAsync(async ct =>
        {
            given = ct;
            started.TrySetResult();
            try { await Task.Delay(Timeout.InfiniteTimeSpan, ct); }
            catch (OperationCanceledException e) { cancelled.TrySetResult(e.CancellationToken); throw; }
            finishedOtherwise = true;
            return GatewayCompatibility.Compatible;
        }, TimeSpan.FromMilliseconds(100));
        Assert.Equal(CompatibilityKind.Unknown, answer.Kind);
        await started.Task.WaitAsync(Evidence);
        var token = await cancelled.Task.WaitAsync(Evidence);
        Assert.Equal(given, token); // the cap's own token, not some other cancellation
        Assert.True(token.IsCancellationRequested);
        Assert.False(finishedOtherwise);
    }

    [Fact]
    public async Task TheCapKeepsItsProductionTimeAndAFailedReadIsUnknown()
    {
        Assert.Equal(TimeSpan.FromSeconds(4), GatewayCompatibility.CheckTime);
        Assert.Equal(GatewayCompatibility.CheckTime, new UpdateHermesModel("Studio", new OutdatedGateway("", "2026.9.1"),
            _ => Task.FromResult(GatewayCompatibility.Unknown), () => { }).Cap);
        var failing = await GatewayCompatibility.CappedAsync(_ => throw new GatewayException("offline", "x"));
        Assert.Equal(CompatibilityKind.Unknown, failing.Kind);
        var faulted = await GatewayCompatibility.CappedAsync(_ => Task.FromException<GatewayCompatibility>(new GatewayException("offline", "x")));
        Assert.Equal(CompatibilityKind.Unknown, faulted.Kind);
    }

    [Fact]
    public async Task AFastReadKeepsItsOwnAnswerAndIsNeverCancelled()
    {
        CancellationToken seen = default;
        var outdated = GatewayCompatibility.From(S("""{"version":"0.21.5","release_date":"2026.9.10"}"""));
        var answer = await GatewayCompatibility.CappedAsync(ct => { seen = ct; return Task.FromResult(outdated); });
        Assert.Same(outdated, answer);
        Assert.Equal(new OutdatedGateway("0.21.5", "2026.9.10"), answer.Outdated);
        Assert.False(seen.IsCancellationRequested);
        Assert.Equal(CompatibilityKind.Compatible,
            (await GatewayCompatibility.CappedAsync(_ => Task.FromResult(GatewayCompatibility.Compatible))).Kind);
    }

    [Fact]
    public async Task CheckAgainEntersOnceNewEnoughAndSaysWhenStillOlder()
    {
        var answers = new Queue<GatewayCompatibility>([
            GatewayCompatibility.From(JsonNode.Parse("""{"version":"0.21.6","release_date":"2026.9.15"}""")),
            GatewayCompatibility.Unknown, // slow, restarting or unreadable: enters (D11)
        ]);
        var entered = 0;
        var model = new UpdateHermesModel("Studio", new OutdatedGateway("0.21.5", "2026.9.10"),
            _ => Task.FromResult(answers.Dequeue()), () => entered++);
        await model.CheckAgainAsync();
        Assert.Equal(UpdateHermesModel.Phase.StillOutdated, model.State);
        Assert.Equal("Still the older version. An update can take a few minutes.", model.Status);
        Assert.Equal("Hermes 0.21.6 · released 2026.9.15", model.Release);
        Assert.Equal(0, entered);
        await model.CheckAgainAsync();
        Assert.Equal(1, entered);
        model.ContinueAnyway(); // once it has left, nothing more
        await model.CheckAgainAsync();
        Assert.Equal(1, entered);

        var other = new UpdateHermesModel("Beta", new OutdatedGateway("", "2026.9.1"), _ => Task.FromResult(GatewayCompatibility.Unknown), () => entered++);
        other.ContinueAnyway();
        Assert.Equal(2, entered);
    }
}

public class GatewayNewsTests
{
    private static Bot B(string name, string id, double last, long count = 3) => new(name, name, null, null, name == "default", false,
        false, null, false, new SessionRef(id, null, null, null, null, DateTimeOffset.FromUnixTimeSeconds((long)last), count), null);

    [Fact]
    public void CountsChatsAnsweredSinceThisPcLastSawThem()
    {
        var chats = GatewayNews.Parked([B("default", "c1", 100), B("mail", "c2", 200), B("empty", "c3", 50, count: 0)]);
        Assert.Equal(["c1", "c2"], chats.Select(c => c.Id));
        Assert.Null(chats[0].Profile);
        Assert.Equal("mail", chats[1].Profile);
        var live = new[] { new ParkedChatLive("c1", 150, 4), new ParkedChatLive("c2", 200, 9) };
        Assert.Equal(1, GatewayNews.UnreadCount(chats, live));
        // No baseline: not news. A marked chat always is. An empty chat isn't.
        Assert.Equal(0, GatewayNews.UnreadCount([new ParkedChat("x", "x", null, null)], [new ParkedChatLive("x", 99, 2)]));
        Assert.Equal(1, GatewayNews.UnreadCount([new ParkedChat("c", "c", null, 10, Marked: true)], []));
        Assert.Equal(0, GatewayNews.UnreadCount([new ParkedChat("c", "c", null, 10)], [new ParkedChatLive("c", 20, 0)]));
        Assert.Equal(40, GatewayNews.Parked(Enumerable.Range(0, 50).Select(i => B($"b{i}", $"s{i}", 1))).Count);
    }

    [Fact]
    public void Labels()
    {
        Assert.Equal("1 New", GatewayNews.NewsLabel(1));
        Assert.Equal("9+ New", GatewayNews.NewsLabel(12));
        Assert.Null(GatewayNews.NewsLabel(0));
        Assert.Equal("Bots, on Studio, 2 new on other gateways", GatewayNews.SwitcherLabel("Bots", "Studio", null, null, 2));
        Assert.Equal("Bots, switching to Beta", GatewayNews.SwitcherLabel("Bots", "Studio", "Beta", "Offline", 2));
        Assert.Equal("On Studio, offline, more than 9 new on other gateways", GatewayNews.SwitcherLabel(null, "Studio", null, "Offline", 12));
        Assert.Equal("On Studio, reconnecting", GatewayNews.SwitcherLabel(null, "Studio", null, "Reconnecting…", 0));
    }
}

public class GatewayHubTests
{
    private static StoredAccount Acc(string url, string user, bool session = true, string? label = null) =>
        new(url, user, session ? [new SavedCookie("hermes_session", "v-" + user, "x", "/", null, false)] : null, Label: label);

    private static (MemoryTokenStore, GatewayHub, MemoryParkedRosters) Hub(params StoredAccount[] accounts)
    {
        var store = new MemoryTokenStore();
        var saved = new SavedAccounts();
        foreach (var a in Enumerable.Reverse(accounts)) saved.Upsert(a);
        store.Write(saved.ToJson());
        var parked = new MemoryParkedRosters();
        var hub = new GatewayHub(store, parked) { CurrentKey = saved.Current };
        return (store, hub, parked);
    }

    private sealed class FakeReader(Func<string, ParkedAnswer> answer) : IParkedReader
    {
        public int Reads;
        public Task<ParkedAnswer> ReadAsync(string id, string? profile, CancellationToken ct)
        {
            Reads++;
            return Task.FromResult(answer(id));
        }
        public void Dispose() { }
    }

    [Fact]
    public void SavedListKeepsLabelsAndMovesOnSelectAndRemove()
    {
        var saved = new SavedAccounts();
        saved.Upsert(Acc("https://a.example", "qa", label: "Home"));
        saved.Upsert(Acc("https://b.example", "qa"));
        saved.Upsert(Acc("https://a.example", "qa")); // a new sign-in without a Name keeps the old one
        Assert.Equal("Home", saved.Accounts[0].Label);
        Assert.Equal("https://a.example\nqa", saved.Current);
        Assert.True(saved.Select("https://b.example\nqa"));
        Assert.Equal("https://b.example", saved.Accounts[0].Url);
        Assert.False(saved.Select("nope"));
        saved.Remove("https://b.example\nqa");
        Assert.Equal("https://a.example\nqa", saved.Current);
        saved.Remove("https://a.example\nqa");
        Assert.Null(saved.Current);
        Assert.False(SavedAccounts.TryFromJson("not json", out _));
        Assert.True(SavedAccounts.TryFromJson(null, out var empty) && empty.Accounts.Count == 0);
    }

    [Fact]
    public void RowsSwitchAndRename()
    {
        var (store, hub, _) = Hub(Acc("https://studio.tail1.ts.net", "owner"), Acc("https://beta.example.com", "qa"),
            Acc("http://100.64.1.2:9119", "old", session: false));
        var rows = hub.Rows;
        Assert.Equal(["Studio", "Beta", "100.64.1.2:9119"], rows.Select(r => r.Title));
        Assert.True(rows[0].IsCurrent);
        Assert.Equal("In Use", rows[0].MenuStatus(rows));
        Assert.Equal("Signed Out", rows[2].MenuStatus(rows));
        Assert.Equal("old · Signed Out", rows[2].Subtitle);

        // A gateway whose session ended signs in again first.
        var e = Assert.Throws<GatewayNeedsSignInException>(() => hub.BeginSwitch(rows[2].Key));
        Assert.Equal("old", e.Account.Username);
        Assert.Null(hub.SwitchingTo);

        var changes = 0;
        hub.Changed += () => changes++;
        hub.BeginSwitch(rows[1].Key);
        Assert.Equal(rows[1].Key, hub.SwitchingTo);
        Assert.Throws<InvalidOperationException>(() => hub.BeginSwitch(rows[0].Key));
        hub.EndSwitch(switched: true);
        Assert.Null(hub.SwitchingTo);
        Assert.Equal(rows[1].Key, SavedAccounts.FromJson(store.Read()).Current);
        Assert.Equal("Beta", hub.Rows.First(r => r.IsCurrent).Title);
        Assert.True(changes >= 2);

        // A failed switch changes nothing.
        hub.BeginSwitch(rows[0].Key);
        hub.EndSwitch(switched: false);
        Assert.Equal("Beta", hub.CurrentTitle);

        hub.Rename(rows[0].Key, "  Home Mac  ");
        Assert.Equal("Home Mac", hub.Rows.First(r => r.Key == rows[0].Key).Title);
        Assert.Equal("Home Mac", hub.Rows.First(r => r.Key == rows[0].Key).Label);
        hub.Rename(rows[0].Key, " ");
        Assert.Equal("Studio", hub.Rows.First(r => r.Key == rows[0].Key).Title);
        Assert.Throws<GatewayException>(() => hub.Rename("nope", "x"));
    }

    [Fact]
    public void TwinNamesShowTheirAddressInTheMenu()
    {
        var (_, hub, _) = Hub(Acc("http://studio.local:9119", "a"), Acc("http://studio.local:9120", "b"));
        var rows = hub.Rows;
        Assert.Equal("studio.local:9119 · In Use", rows[0].MenuStatus(rows));
        Assert.Equal("studio.local:9120", rows[1].MenuStatus(rows));
    }

    [Fact]
    public async Task RemoveRefusesTheOneInUseAndForgetsTheOther()
    {
        var (store, hub, parked) = Hub(Acc("https://a.example", "qa"), Acc("https://b.example", "qa", session: false));
        var keys = hub.Rows.Select(r => r.Key).ToList();
        parked.Write(keys[1], [new ParkedChat("x", "x", null, 1)]);
        await Assert.ThrowsAsync<GatewayException>(() => hub.RemoveAsync(keys[0]));
        var purged = new List<string>();
        await hub.RemoveAsync(keys[1], purged.Add);
        Assert.Equal([keys[1]], purged);
        Assert.Single(SavedAccounts.FromJson(store.Read()).Accounts);
        Assert.Null(parked.Read(keys[1]));
        Assert.Equal(keys[0], SavedAccounts.FromJson(store.Read()).Current);
    }

    [Fact]
    public async Task NewsCheckCountsRefusesAndBacksOff()
    {
        var (_, hub, parked) = Hub(Acc("https://a.example", "qa"), Acc("https://b.example", "qa"), Acc("https://c.example", "qa"));
        var keys = hub.Rows.Select(r => r.Key).ToList();
        parked.Write(keys[1], [new ParkedChat("default", "s1", null, 100), new ParkedChat("mail", "s2", "mail", 100)]);
        parked.Write(keys[2], [new ParkedChat("default", "t1", null, 100)]);
        var now = DateTimeOffset.UnixEpoch;
        hub.Now = () => now;
        var unreachable = true;
        hub.MakeReader = a => a.Url == "https://b.example"
            ? new FakeReader(id => new ParkedAnswer.Session(JsonNode.Parse(id == "s1"
                ? """{"last_active":150,"message_count":4}""" : """{"last_active":90,"message_count":4}""")!))
            : unreachable ? new ThrowingReader() : new FakeReader(_ => new ParkedAnswer.Refused());

        await hub.CheckAsync(force: false);
        var rows = hub.Rows;
        Assert.Equal(1, rows[1].News);
        Assert.Equal("1 New", rows[1].MenuStatus(rows));
        Assert.True(rows[2].Unreachable);
        Assert.Equal("Can’t Reach", rows[2].MenuStatus(rows));
        Assert.Equal(1, hub.OtherNews);

        // Backed off: the unreachable gateway isn't asked again for 6 minutes unless the menu asks (force).
        unreachable = false;
        now += TimeSpan.FromMinutes(1);
        await hub.CheckAsync(force: false);
        Assert.True(hub.Rows[2].Unreachable);
        Assert.Equal(TimeSpan.FromMinutes(6), GatewayHub.Backoff(1));
        Assert.Equal(TimeSpan.FromMinutes(12), GatewayHub.Backoff(2));
        Assert.Equal(TimeSpan.FromMinutes(30), GatewayHub.Backoff(9));
        await hub.CheckAsync(force: true);
        // Refused: shown signed out (the saved copy stays), no news.
        Assert.False(hub.Rows[2].Unreachable);
        Assert.False(hub.Rows[2].HasSession);
        Assert.Equal("Signed Out", hub.Rows[2].MenuStatus(hub.Rows));
        Assert.Throws<GatewayNeedsSignInException>(() => hub.BeginSwitch(keys[2]));

        // The gateway in use has no news of its own here; a switch clears the one switched to.
        hub.BeginSwitch(keys[1]);
        hub.EndSwitch(true);
        Assert.Equal(0, hub.Rows.First(r => r.Key == keys[1]).News);
    }

    private sealed class ThrowingReader : IParkedReader
    {
        public Task<ParkedAnswer> ReadAsync(string id, string? profile, CancellationToken ct) =>
            throw new GatewayException("offline", "Can't reach the gateway.");
        public void Dispose() { }
    }

    [Fact]
    public void RestoreSaysWhatALaunchFinds()
    {
        var store = new MemoryTokenStore();
        var signIn = new SignIn(store);
        Assert.IsType<SignIn.RestoreState.SignedOut>(signIn.Restore());
        var saved = new SavedAccounts();
        saved.Upsert(Acc("https://a.example", "qa", session: false));
        store.Write(saved.ToJson());
        var prefill = Assert.IsType<SignIn.RestoreState.SignedOut>(signIn.Restore());
        Assert.Equal("qa", prefill.Prefill!.Username);
        saved.Upsert(Acc("https://a.example", "qa"));
        store.Write(saved.ToJson());
        var resumed = Assert.IsType<SignIn.RestoreState.SignedIn>(signIn.Restore());
        resumed.Session.Dispose();
        store.Write("{garbage");
        Assert.Equal("keychain-unreadable", Assert.IsType<SignIn.RestoreState.Unavailable>(signIn.Restore()).Reason);
        Assert.Equal("keychain-unavailable", Assert.IsType<SignIn.RestoreState.Unavailable>(new SignIn(new LockedStore()).Restore()).Reason);
        Assert.Equal("Home", SignIn.AccountLabel("  Home  "));
        Assert.Null(SignIn.AccountLabel("   "));
        Assert.Equal(60, SignIn.AccountLabel(new string('x', 80))!.Length);
    }

    private sealed class LockedStore : ITokenStore
    {
        public string? Read() => throw new TokenStoreUnavailableException("locked");
        public void Write(string json) { }
        public void Delete() { }
    }
}
