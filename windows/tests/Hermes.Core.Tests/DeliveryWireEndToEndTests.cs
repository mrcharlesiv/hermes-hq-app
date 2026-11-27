// [WIN-DELIVERY-WALK] The chat-delivery walk's Core half over the real wire: a signed-in HermesClient's ChatSession
// against windows/ci/fixtures/performance-fixture-gateway.py (its own instance, so no other test takes its plans), with
// the walk's own plans and checks (Hermes.Core/Shell/DeliveryWalkProof.cs): a send refused 4090
// SESSION_OWNER_UNCONFIRMED is marked and never resent, and Check finds nothing; SESSION_NOT_OWNED four times waits
// (the background task's card and status) and then sends once; 4001 profile_mismatch locks the chat with the words
// back; the add-on's ledger and a stored prompt another app wrote make Sam's chat say Working…, and the ledger going
// idle ends it. Run through windows/scripts/e2e.sh (HQW_E2E_DELIVERY_CREDENTIALS); without it this passes vacuously.

using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Chat;
using Hermes.Core.Net;
using Proof = Hermes.Core.Shell.DeliveryWalkProof;

namespace Hermes.Core.Tests;

[Trait("Category", "E2E")]
public sealed class DeliveryWireEndToEndTests
{
    private static async Task<JsonNode> Record(string url)
    {
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
        return JsonNode.Parse(await http.GetStringAsync(url.TrimEnd('/') + Proof.StandIn))!;
    }

    private static async Task Post(string url, string path, string body)
    {
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
        (await http.PostAsync(url.TrimEnd('/') + path, new StringContent(body, System.Text.Encoding.UTF8, "application/json"))).EnsureSuccessStatusCode();
    }

    private static async Task<string?> Until(Func<string?> check, int seconds = 15)
    {
        var until = DateTime.UtcNow.AddSeconds(Math.Max(10, seconds));
        string? last;
        while ((last = check()) != null && DateTime.UtcNow < until) await Task.Delay(50);
        return last;
    }

    [Fact]
    public async Task TheDeliveryCardsComeFromTheGatewaysRefusalsAndLedger()
    {
        var path = Environment.GetEnvironmentVariable("HQW_E2E_DELIVERY_CREDENTIALS");
        if (path == null || !File.Exists(path)) return;
        var cred = JsonNode.Parse(File.ReadAllText(path))!;
        var url = cred.Str("url")!;
        var session = await new SignIn(new MemoryTokenStore()).PasswordAsync(GatewayAddress.FromTyped(url), cred.Str("username")!, cred.Str("password")!);
        await using var client = new HermesClient(session);
        await client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(30)).Token);
        await Post(url, Proof.WorkingPath, Proof.IdleBody());   // the add-on answers (nothing runs yet)
        var bots = await client.BotsAsync();
        var hermes = bots.Single(b => b.Name == Proof.Bot);
        await using var chat = client.OpenChat(hermes.Name, await client.BotChatIdAsync(hermes), hermes.DisplayName);
        await chat.OpenAsync();

        // 1. Delivery unconfirmed: marked, never resent; Check reads the stored rows and finds nothing.
        await Post(url, Proof.PlanPath, Proof.UnconfirmedPlan());
        var mark = Proof.Mark(await Record(url));
        Assert.Equal(SendOutcome.Unconfirmed, await chat.SendAsync(Proof.UnconfirmedText));
        Assert.Null(Proof.Unconfirmed(chat.Messages));
        var mine = chat.Messages.Last(m => m.Text == Proof.UnconfirmedText);
        Assert.False(await chat.CheckDeliveryAsync(mine.Id));
        Assert.Null(Proof.Unconfirmed(chat.Messages));
        Assert.Null(Proof.UnconfirmedWire(await Record(url), mark));

        // 2. Owned by a one-shot run: the background task's card and status while it waits, then one send.
        await Post(url, Proof.PlanPath, Proof.OwnerWaitPlan());
        mark = Proof.Mark(await Record(url));
        var send = chat.SendAsync(Proof.OwnerText);
        Assert.Null(await Until(() => chat.OwnerWaitNotice is { } w
            ? Proof.OwnerWaitCard(OwnerWait.CardTitle, w.CardBody, OwnerWait.CancelTitle) : "no waiting card"));
        Assert.Equal(Proof.OwnerWaitStatus, chat.Status);
        Assert.Equal(SendOutcome.Accepted, await send);
        Assert.Null(chat.OwnerWaitNotice);
        Assert.Null(await Until(() => chat.Busy ? "busy" : Proof.OwnerSent(chat.Messages), 20));
        Assert.Null(Proof.OwnerWire(await Record(url), mark));

        // 3. Locked: the problem card, the words back, one try.
        await Post(url, Proof.PlanPath, Proof.LockedPlan());
        mark = Proof.Mark(await Record(url));
        string? back = null;
        chat.DraftReturned += (draft, _) => back = draft;
        Assert.Equal(SendOutcome.Refused, await chat.SendAsync(Proof.LockedText));
        Assert.NotNull(chat.SessionProblem);
        Assert.Null(chat.SendFailure);
        Assert.Null(Proof.LockedCard(chat.SessionProblem!.Title, chat.SessionProblem.Body, back));
        Assert.Null(Proof.LockedWire(await Record(url), mark));

        // 4. Another app's turn in Sam's chat: a prompt stored just now, the ledger names the chat: Working….
        var sam = bots.Single(b => b.Name == Proof.ExternalBot);
        var samId = await client.BotChatIdAsync(sam);
        await Post(url, Proof.ExternalPath, Proof.ExternalBody());
        await Post(url, Proof.WorkingPath, Proof.WorkingBody(samId));
        await using var other = client.OpenChat(sam.Name, samId, sam.DisplayName);
        await other.OpenAsync();
        Assert.Null(await Until(() => Proof.Header(other.Status)));
        Assert.Equal(ExternalTurn.Source.Ledger, other.ExternalWork);
        Assert.Contains(other.Messages, m => m.Text == Proof.ExternalText);
        // The ledger goes idle: Working… ends (the watch reads every 3 s).
        await Post(url, Proof.WorkingPath, Proof.IdleBody());
        await Post(url, Proof.FinishPath, """{"profile":"sam","text":"Synthetic answer to the other app."}""");
        Assert.Null(await Until(() => other.Status == null ? null : $"still \"{other.Status}\"", 15));
    }
}
