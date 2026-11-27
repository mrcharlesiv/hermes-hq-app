using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Gateways;
using Hermes.Core.Net;
using Hermes.Core.Rpc;

namespace Hermes.Core.Tests;

/// Two gateways at once (scripts/fixtures/onboarding-gateway.py, run twice by windows/scripts/e2e.sh): A is current,
/// B is an older Hermes. Sign in to both with one store, the version check and Check Again, switch, the news read with
/// a parked account's own session, rename, remove, and the retry surface of a gateway that isn't there.
/// Without HQW_E2E_GW_A / HQW_E2E_GW_B these pass vacuously.
[Trait("Category", "E2E")]
public class GatewaysEndToEndTests
{
    private static (string Url, string User, string Password)? Creds(string variable)
    {
        var path = Environment.GetEnvironmentVariable(variable);
        if (path == null || !File.Exists(path)) return null;
        var j = JsonNode.Parse(File.ReadAllText(path))!;
        return (j.Str("url")!, j.Str("username")!, j.Str("password")!);
    }

    private static async Task Control(string url, string path, object body)
    {
        using var http = new HttpClient();
        var content = new StringContent(System.Text.Json.JsonSerializer.Serialize(body), System.Text.Encoding.UTF8, "application/json");
        (await http.PostAsync(url.TrimEnd('/') + path, content)).EnsureSuccessStatusCode();
    }

    [Fact]
    public async Task TwoGatewaysSignInCheckSwitchNewsRenameRemove()
    {
        if (Creds("HQW_E2E_GW_A") is not var (aUrl, aUser, aPassword) || Creds("HQW_E2E_GW_B") is not var (bUrl, bUser, bPassword)) return;
        await Control(aUrl, "/__onboarding/reset", new { });
        await Control(bUrl, "/__onboarding/reset", new { });
        var store = new MemoryTokenStore();
        var signIn = new SignIn(store);
        var hub = new GatewayHub(store, new MemoryParkedRosters());

        // A, named on this PC; new enough.
        var a = await signIn.PasswordAsync(GatewayAddress.FromTyped(aUrl), aUser, aPassword, default, "  Home Server ");
        Assert.Equal(CompatibilityKind.Compatible, (await GatewayCompatibility.CappedAsync(ct => SignIn.CompatibilityAsync(a, ct))).Kind);
        hub.CurrentKey = a.Account.Key;
        await using (var client = new HermesClient(a))
        {
            await client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(15)).Token);
            Assert.True(client.Rpc.EverOpen);
            // Two reads at once (the launch's first read and the sidebar's): one roster read, one answer.
            var first = client.BotsAsync();
            var second = client.BotsAsync();
            var bots = await first;
            Assert.Same(bots, await second);
            Assert.Same(bots, client.Bots);
            Assert.NotEmpty(bots);
            hub.Park(a.Account.Key, bots);
        }

        // B, an older Hermes: the sign-in is saved and current, then "Update Hermes".
        var b = await signIn.PasswordAsync(GatewayAddress.FromTyped(bUrl), bUser, bPassword);
        var outdated = (await GatewayCompatibility.CappedAsync(ct => SignIn.CompatibilityAsync(b, ct))).Outdated;
        Assert.Equal("2026.9.10", outdated?.ReleaseDate);
        Assert.Equal(b.Account.Key, SavedAccounts.FromJson(store.Read()).Current);
        hub.CurrentKey = b.Account.Key;
        var entered = false;
        var update = new UpdateHermesModel(GatewayNaming.UpdateName(b.Address.Base, null), outdated!,
            ct => SignIn.CompatibilityAsync(b, ct), () => entered = true);
        Assert.Equal("Your Gateway", update.Name);
        await update.CheckAgainAsync();
        Assert.Equal(UpdateHermesModel.Phase.StillOutdated, update.State);
        await Control(bUrl, "/__onboarding/status", new { release_date = "2026.10.20" });
        await update.CheckAgainAsync();
        Assert.True(entered);

        var rows = hub.Rows;
        Assert.Equal(["127.0.0.1:" + b.Address.Base.Port, "Home Server"], rows.Select(r => r.Title));
        Assert.True(rows[0].IsCurrent);
        Assert.Equal("127.0.0.1:" + a.Address.Base.Port + " · " + aUser, rows[1].Subtitle);

        // News on A, read with A's own session while B is in use: nothing since A was parked; then everything
        // answered since an older sighting is news.
        await hub.CheckAsync();
        Assert.Equal(0, hub.Rows[1].News);
        Assert.False(hub.Rows[1].Unreachable);
        var parked = new MemoryParkedRosters();
        var older = new GatewayHub(store, parked) { CurrentKey = b.Account.Key };
        using (var again = signIn.Resume(SavedAccounts.FromJson(store.Read()).Find(a.Account.Key)!)!)
        await using (var client = new HermesClient(again))
        {
            var bots = await client.BotsAsync();
            parked.Write(a.Account.Key, [.. GatewayNews.Parked(bots).Select(c => c with { Baseline = 1 })]);
            await older.CheckAsync();
            Assert.InRange(older.Rows[1].News, 1, GatewayNews.Parked(bots).Count);
            Assert.Equal(older.Rows[1].News, older.OtherNews);
        }

        // Switch to A: its saved session resumes and the socket opens.
        var target = hub.BeginSwitch(a.Account.Key);
        var resumed = signIn.Resume(target)!;
        hub.EndSwitch(switched: true);
        Assert.Equal(a.Account.Key, SavedAccounts.FromJson(store.Read()).Current);
        await using (var client = new HermesClient(resumed))
            await client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(15)).Token);
        Assert.Equal("Home Server", hub.CurrentTitle);

        // Rename B, then remove it (its own logout, the entry, its parked bots).
        hub.Rename(b.Account.Key, "Beta");
        Assert.Equal("Beta", hub.Rows.First(r => r.Key == b.Account.Key).Title);
        await Assert.ThrowsAsync<GatewayException>(() => hub.RemoveAsync(a.Account.Key));
        await hub.RemoveAsync(b.Account.Key);
        Assert.Equal([a.Account.Key], SavedAccounts.FromJson(store.Read()).Accounts.Select(x => x.Key));
        Assert.Equal(a.Account.Key, SavedAccounts.FromJson(store.Read()).Current);
        a.Dispose();
        b.Dispose();
    }

    [Fact]
    public async Task AGatewayThatIsntThereCountsDownAndTriesAgainOnRequest()
    {
        if (Creds("HQW_E2E_GW_A") is not var (aUrl, _, _)) return;
        var port = new Uri(aUrl).Port + 2; // nothing listens there (e2e.sh keeps it free)
        var account = new StoredAccount($"http://127.0.0.1:{port}", "qa", [new SavedCookie("hermes_session", "x", "127.0.0.1", "/", null, false)]);
        var session = new SignIn(new MemoryTokenStore()).Resume(account)!;
        await using var client = new HermesClient(session);
        var until = DateTime.UtcNow.AddSeconds(10);
        while (client.Rpc.NextRetry == null && DateTime.UtcNow < until) await Task.Delay(50);
        Assert.Equal(ConnectionState.Offline, client.Rpc.State);
        Assert.Equal("unreachable", client.Rpc.LastFailure);
        Assert.False(client.Rpc.EverOpen);
        var due = client.Rpc.NextRetry!.Value;
        Assert.InRange((due - DateTimeOffset.UtcNow).TotalSeconds, 0, 3.1); // the ladder's first step
        var dials = client.Rpc.FailedDials;
        client.Rpc.ReconnectNow();
        until = DateTime.UtcNow.AddSeconds(5);
        while (client.Rpc.FailedDials == dials && DateTime.UtcNow < until) await Task.Delay(50);
        Assert.Equal(dials + 1, client.Rpc.FailedDials);
        Assert.True(DateTimeOffset.UtcNow < due, "Try Again dialled before the countdown ran out");
    }
}
