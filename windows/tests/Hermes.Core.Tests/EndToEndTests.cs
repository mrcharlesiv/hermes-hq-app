using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Model;
using Hermes.Core.Net;

namespace Hermes.Core.Tests;

/// The M1 wire walk (spec 05 §A12) against performance-fixture-gateway.py. Run through windows/scripts/e2e.sh,
/// which starts the fixture and sets HQW_E2E_CREDENTIALS; without it these tests pass vacuously.
[Trait("Category", "E2E")]
public class EndToEndTests
{
    private static (string Url, string User, string Password)? Credentials()
    {
        var path = Environment.GetEnvironmentVariable("HQW_E2E_CREDENTIALS");
        if (path == null || !File.Exists(path)) return null;
        var j = JsonNode.Parse(File.ReadAllText(path))!;
        return (j.Str("url")!, j.Str("username")!, j.Str("password")!);
    }

    private static async Task Until(Func<bool> condition, int seconds = 15)
    {
        var until = DateTime.UtcNow.AddSeconds(seconds);
        while (!condition())
        {
            if (DateTime.UtcNow > until) throw new TimeoutException("condition not met");
            await Task.Delay(50);
        }
    }

    private static async Task Plan(string url, object plan)
    {
        using var http = new HttpClient();
        var body = new StringContent(System.Text.Json.JsonSerializer.Serialize(new { plans = new[] { plan } }),
            System.Text.Encoding.UTF8, "application/json");
        (await http.PostAsync(url.TrimEnd('/') + "/__fixture/plan", body)).EnsureSuccessStatusCode();
    }

    [Fact]
    public async Task SignInBotsChatSendStreamStop()
    {
        if (Credentials() is not var (url, user, password)) return;
        var store = new MemoryTokenStore();
        var signIn = new SignIn(store);
        var gw = GatewayAddress.FromTyped(url);

        var probe = await signIn.ProbeAsync(gw);
        Assert.True(probe.Password);
        await Assert.ThrowsAsync<GatewayException>(() => signIn.PasswordAsync(gw, user, "wrong-password"));

        var session = await signIn.PasswordAsync(gw, user, password);
        Assert.True(session.Account.IsSignedIn);
        Assert.Contains("cookies", store.Read()!);
        Assert.DoesNotContain(password, store.Read()!);

        await using var client = new HermesClient(session);
        await client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(15)).Token);

        var bots = await client.BotsAsync();
        var hermes = bots.First(b => b.Name == "default");
        var chatId = await client.BotChatIdAsync(hermes);

        await using var chat = client.OpenChat(hermes.Name, chatId, hermes.DisplayName);
        await chat.OpenAsync();
        var before = chat.Messages.Count;

        // A streamed reply with tools.
        await Plan(url, new { chunks = new[] { "Let me ", "run ", "three steps. ", "All done." }, tools = 3, toolBytes = 64 });
        await chat.SendAsync("Run three steps");
        await Until(() => !chat.Busy && chat.Messages.LastOrDefault()?.Text.Contains("All done.") == true);
        var reply = chat.Messages.Last();
        Assert.Equal(Role.Assistant, reply.Role);
        Assert.Equal(3, reply.Tools.Count());
        Assert.True(chat.Messages.Count >= before + 2);
        // The turn-end history read replaces local bubbles with stored rows.
        await Until(() => chat.Messages.All(m => !m.Id.StartsWith("local-")));

        // Stop mid-stream.
        await Plan(url, new { chunks = Enumerable.Range(0, 200).Select(i => $"word{i} ").ToArray(), chunkDelay = 0.05 });
        await chat.SendAsync("Write a long answer");
        await Until(() => chat.Messages.LastOrDefault()?.Text.StartsWith("word0") == true);
        await chat.StopAsync();
        Assert.False(chat.Busy);
        var stoppedAt = chat.Messages.Last(m => m.Role == Role.Assistant).Text;
        await Task.Delay(500);
        Assert.DoesNotContain("word199", chat.Messages.Last(m => m.Role == Role.Assistant).Text);
        Assert.StartsWith("word0", stoppedAt);

        // The sidebar reads.
        var sidebar = await client.SessionsAsync();
        Assert.False(sidebar.Recents.Failed);

        // Restore from the saved account at "launch".
        var restored = await new SignIn(store).RestoreAsync();
        Assert.NotNull(restored);
        restored!.Dispose();
    }
}

/// Sign in with Nous against nous-fixture-gateway.py: PKCE, loopback catch, token exchange, bearer REST, ws ticket,
/// and a rotation of the 4 s access token with no refresh-token replay.
[Trait("Category", "E2E")]
public class NousEndToEndTests
{
    /// Stands in for the system browser: follows the gateway's redirects to the fake Portal, clicks
    /// "Continue as owner", and lets the redirect chain land on the app's loopback relay.
    private static async Task FakeBrowser(Uri authorize)
    {
        var handler = new HttpClientHandler { CookieContainer = new System.Net.CookieContainer(), AllowAutoRedirect = true };
        using var browser = new HttpClient(handler);
        var portal = await browser.GetStringAsync(authorize);
        var href = System.Text.RegularExpressions.Regex.Match(portal, "href=\"([^\"]+)\"").Groups[1].Value;
        var landed = await browser.GetStringAsync(System.Net.WebUtility.HtmlDecode(href));
        Assert.Contains("Signed in", landed);
    }

    [Fact]
    public async Task NousSignInRotatesWithoutReplay()
    {
        var url = Environment.GetEnvironmentVariable("HQW_E2E_NOUS_URL");
        if (url == null) return;
        var store = new MemoryTokenStore();
        var signIn = new SignIn(store);
        var gw = GatewayAddress.FromTyped(url);
        Assert.True((await signIn.ProbeAsync(gw)).Nous);

        var session = await signIn.NousAsync(gw, u => Task.Run(() => FakeBrowser(u)));
        Assert.StartsWith("nous:", session.Account.Username);
        var first = session.Account.Nous!;

        await using var client = new HermesClient(session);
        await client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(15)).Token);
        Assert.NotEmpty(await client.BotsAsync());

        await Task.Delay(TimeSpan.FromSeconds(5)); // the 4 s access token is now past due
        await Task.WhenAll(Enumerable.Range(0, 4).Select(_ => client.SessionsAsync())); // concurrent: one renewal
        var rotated = session.Account.Nous!;
        Assert.NotEqual(first.RefreshToken, rotated.RefreshToken);
        Assert.Contains(rotated.RefreshToken, store.Read()!);

        using var http = new HttpClient();
        var counts = JsonNode.Parse(await http.GetStringAsync(url + "/__fixture/nous"))!.Obj("counts");
        Assert.Equal(0, counts.Int("refreshReplayed"));
        Assert.True(counts.Int("refresh") >= 1);
    }
}
