// [WIN-SCREEN-SETUP-SEND-WALK] The bot-screen-setup-send walk's Core checks (Hermes.Core/Shell/ScreenSetupWalkProof.cs)
// against windows/ci/fixtures/screen-gateway.py over the real wire: a signed-in HermesClient, otto's bot chat as the
// roster gives it (profiles.list), its ChatComposer, and the app's ScreenSetupRequester (Set Up with Hermes, the Mac's
// runScreenSetup) over a host that stands in for the window (closing the Screen, opening the bot chat) and loads the
// reviewed installer the app ships. The stand-in records file.attach then prompt.submit; the checks hold them to the
// Mac's params and words, the chat shows the short-titled bubble (the stand-in's reply held back 2.5 s) and then the reply, and a second press
// in the same run sends nothing (the ledger's "already there"). Run through windows/scripts/e2e.sh
// (HQW_E2E_SCREEN_CREDENTIALS); without it this passes vacuously.

using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Composer;
using Hermes.Core.Net;
using Hermes.Core.Screen;
using Hermes.Core.Shell;
using Proof = Hermes.Core.Shell.ScreenSetupWalkProof;

namespace Hermes.Core.Tests.Screen;

[Trait("Category", "E2E")]
[Collection("ScreenSession")]
public sealed class ScreenSetupWireEndToEndTests
{
    private static async Task<JsonNode> Record(string url)
    {
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
        return JsonNode.Parse(await http.GetStringAsync(url.TrimEnd('/') + Proof.StandIn))!;
    }

    private static async Task<string?> UntilWire(string url, Func<JsonNode, string?> check)
    {
        var until = DateTime.UtcNow.AddSeconds(15);
        string? last;
        do
        {
            last = check(await Record(url));
            if (last == null) return null;
            await Task.Delay(200);
        } while (DateTime.UtcNow < until);
        return last;
    }

    private static async Task<bool> Until(Func<bool> done, int seconds = 15)
    {
        var until = DateTime.UtcNow.AddSeconds(Math.Max(10, seconds));
        while (!done())
        {
            if (DateTime.UtcNow > until) return false;
            await Task.Delay(50);
        }
        return true;
    }

    /// The window's side of runScreenSetup: the Screen closes, the bot chat opens in the pane when asked.
    private sealed class Host(string account, ScreenSetupChat botChat, string installer) : IScreenSetupHost
    {
        public bool CoversClosed { get; private set; }
        public string? Opened { get; private set; }
        public List<ScreenSetupError> Failures { get; } = [];
        public List<string> Notes { get; } = [];
        public string? AccountId => account;
        public Task CloseCoversAsync() { CoversClosed = true; return Task.CompletedTask; }
        public IScreenSetupChat? OpenChat() => Opened == botChat.Profile ? botChat : null;
        public void OpenBotChat(string profile) => Opened = profile;
        public IDisposable? ShowOpening(IScreenSetupChat chat) => null;
        public void Failed(ScreenSetupError failure, IScreenSetupChat? chat) => Failures.Add(failure);
        public Task<ScreenSetupBundle> LoadBundleAsync() => ScreenSetupBundle.Load(installer);
        public void Note(string line) => Notes.Add(line);
    }

    private static string Installer()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir != null && !File.Exists(Path.Combine(dir.FullName, "HermesHQ.sln"))) dir = dir.Parent;
        Assert.NotNull(dir);
        return Path.Combine(dir!.FullName, "src", "HermesHQ.Windows", "Screen", ScreenSetupBundle.Resource + ".zip");
    }

    [Fact]
    public async Task SetUpWithHermesAttachesTheInstallerThenSendsTheMacsPromptToOttosChat()
    {
        var path = Environment.GetEnvironmentVariable("HQW_E2E_SCREEN_CREDENTIALS");
        if (path == null || !File.Exists(path)) return;
        var cred = JsonNode.Parse(File.ReadAllText(path))!;
        var url = cred.Str("url")!;
        var session = await new SignIn(new MemoryTokenStore()).PasswordAsync(GatewayAddress.FromTyped(url), cred.Str("username")!, cred.Str("password")!);
        await using var client = new HermesClient(session);
        await client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(30)).Token);

        // otto is in the roster with its own chat (Set Up with Hermes opens it from the bot list).
        var profiles = await client.Rpc.RequestAsync("profiles.list", new JsonObject(), TimeSpan.FromSeconds(15));
        Assert.Null(Proof.Roster(profiles));
        var stored = Proof.StoredSession(profiles)!;

        await using var chat = client.OpenChat(Proof.Bot, stored, Proof.BotName);
        using var composer = new ChatComposer(chat, new ModelPrefs(client.AccountId, new MemoryStore()));
        var host = new Host(client.AccountId, new ScreenSetupChat(composer, isBotChat: true), Installer());
        var requester = new ScreenSetupRequester(host, new ScreenSetupLedger());

        using (var http = new HttpClient { Timeout = TimeSpan.FromSeconds(10) })
            (await http.PostAsync(url.TrimEnd('/') + Proof.Plan, new StringContent(Proof.PlanBody(), System.Text.Encoding.UTF8, "application/json"))).EnsureSuccessStatusCode();
        var mark = Proof.Chat(await Record(url));
        Assert.Null(await requester.RequestAsync(Proof.Bot, resume: false));
        Assert.Empty(host.Failures);
        Assert.True(host.CoversClosed);
        Assert.Equal(Proof.Bot, host.Opened);
        Assert.Contains("setup requested", host.Notes);

        // file.attach then prompt.submit, as the Mac sends them, to otto's chat.
        Assert.Null(await UntilWire(url, r => Proof.Sent(r, mark)));
        Assert.True(await Until(() => Proof.Bubble(chat.Messages) == null), Proof.Bubble(chat.Messages));
        Assert.True(await Until(() => !chat.Busy && Proof.Replied(chat.Messages), 20),
            $"busy {chat.Busy}: " + string.Join(" | ", chat.Messages.Select(m => $"{m.Role}{(m.IsStreaming ? "*" : "")}:{m.Text[..Math.Min(40, m.Text.Length)]}")));

        // The checks are not vacuous: nothing after the send, and a second press in this run sends nothing more.
        var record = await Record(url);
        Assert.NotNull(Proof.Sent(record, Proof.Chat(record)));
        var after = Proof.Chat(record);
        Assert.Null(await requester.RequestAsync(Proof.Bot, resume: false));
        await Task.Delay(500);
        Assert.Equal(after, Proof.Chat(await Record(url)));
        Assert.Empty(host.Failures);
    }
}
