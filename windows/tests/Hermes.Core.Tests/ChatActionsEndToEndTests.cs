using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Chat;
using Hermes.Core.Model;
using Hermes.Core.Net;
using Hermes.Core.Shell;

namespace Hermes.Core.Tests;

/// [WIN-43] Branch in New Chat, Regenerate, Rewind to Here and Edit through Hermes.Core against the composer stand-in
/// (its menus layer records every call in /__menus/state): Branch from Trip planning's latest reply goes as
/// `session.branch {count}` and opens a chat holding those messages; the rewinds go as `prompt.submit` truncating
/// before your stored row with `confirm_truncate` and the loaded row ids, and the chat answers again. Run through
/// windows/scripts/e2e.sh; without the credentials it passes vacuously.
[Collection(ComposerStandIn.Name)]
[Trait("Category", "E2E")]
public class ChatActionsEndToEndTests
{
    private static async Task<JsonNode> Get(string url, string path)
    {
        using var http = new HttpClient();
        return JsonNode.Parse(await http.GetStringAsync(url.TrimEnd('/') + path))!;
    }

    private static async Task Until(Func<bool> condition, int seconds = 20)
    {
        var until = DateTime.UtcNow.AddSeconds(seconds);
        while (!condition())
        {
            if (DateTime.UtcNow > until) throw new TimeoutException("condition not met");
            await Task.Delay(50);
        }
    }

    private static List<JsonNode> Submits(JsonNode state, double mark) =>
        [.. (state.Arr("calls") ?? []).OfType<JsonNode>().Where(c => c.Str("method") == "prompt.submit" && (c.Num("at") ?? 0) > mark)];

    [Fact]
    public async Task BranchRegenerateRewindAndEditGoOverTheWireAsTheMacs()
    {
        var path = Environment.GetEnvironmentVariable("HQW_E2E_COMPOSER_CREDENTIALS");
        if (path == null || !File.Exists(path)) return;
        var cred = JsonNode.Parse(File.ReadAllText(path))!;
        var url = cred.Str("url")!;
        var session = await new SignIn(new MemoryTokenStore()).PasswordAsync(GatewayAddress.FromTyped(url), cred.Str("username")!, cred.Str("password")!);
        await using var client = new HermesClient(session);
        await client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(15)).Token);

        // Branch from Trip planning's latest reply: session.branch with the count of messages through it.
        await using (var trip = client.OpenChat(ChatActionsProof.TripBot, ChatActionsProof.TripStoredId, ChatActionsProof.TripTitle))
        {
            await trip.OpenAsync();
            await Until(() => trip.Messages.Count >= 4 && trip.RuntimeId != null);
            var reply = ChatActionRules.LatestReplyId(trip.Messages)!;
            var count = RewindParams.BranchCount(reply, trip.Messages)!.Value;
            var mark = WalkProof.LastCallAt(await Get(url, "/__menus/state"));
            var branch = await trip.BranchAsync(reply);
            Assert.NotEqual(ChatActionsProof.TripStoredId, branch.StoredId);
            Assert.NotNull(branch.RuntimeId);
            Assert.Null(ChatActionsProof.Branched(await Get(url, "/__menus/state"), mark, count));
            // The branch opens as any chat does, holding the messages through the reply.
            await using var opened = client.OpenChat(ChatActionsProof.TripBot, branch.StoredId, ChatActionWords.BranchTitle(trip.Title));
            await opened.OpenAsync();
            Assert.Equal(count, opened.Messages.Count(m => m.Role is Role.User or Role.Assistant));

            // A message not stored yet can't be branched from.
            var nowhere = await Assert.ThrowsAsync<GatewayException>(() => trip.BranchAsync("not-a-message"));
            Assert.Equal(ChatActionWords.NotInChat, nowhere.Message);
        }

        // The rewinds, in the bot's own chat (whose rows the stand-in truncates).
        var bot = (await client.BotsAsync()).First(b => b.Name == "default");
        await using var chat = client.OpenChat(bot.Name, await client.BotChatIdAsync(bot), bot.DisplayName);
        await chat.OpenAsync();
        Assert.Equal(SendOutcome.Accepted, await chat.SendAsync("Plan the week"));
        await Until(() => !chat.Busy && chat.Messages.LastOrDefault()?.Role == Role.Assistant);
        await chat.RefreshAsync();
        var prompt = chat.Messages.Last(m => m.Role == Role.User);
        Assert.True(chat.CanRewind(prompt.Id));

        // Regenerate: the latest reply's prompt again, truncating before its row.
        var failures = new List<string>();
        var before = WalkProof.LastCallAt(await Get(url, "/__menus/state"));
        Assert.True(chat.Regenerate(failures.Add));
        await chat.RewindSend!;
        var submits = Submits(await Get(url, "/__menus/state"), before);
        var sent = Assert.Single(submits)["params"]!;
        Assert.Equal("Plan the week", sent.Str("text"));
        Assert.Equal(prompt.RowId, (long?)sent.Num("truncate_before_row_id"));
        Assert.True(sent.Bool("confirm_truncate"));
        Assert.Contains(prompt.RowId!.Value, (sent["rebind_survivor_row_ids"] as JsonArray)!.Select(n => (long)n!.GetValue<double>()));
        await Until(() => !chat.Busy && chat.Messages.LastOrDefault()?.Role == Role.Assistant);
        await chat.RefreshAsync();
        Assert.Single(chat.Messages, m => m.Role == Role.User && m.Text == "Plan the week");

        // Edit: your words changed, truncating before the message.
        var mine = chat.Messages.Last(m => m.Role == Role.User);
        before = WalkProof.LastCallAt(await Get(url, "/__menus/state"));
        Assert.True(chat.Edit(mine.Id, mine.Text, failures.Add));   // unchanged: nothing sent
        Assert.True(chat.Edit(mine.Id, "Plan the weekend", failures.Add));
        await chat.RewindSend!;
        sent = Assert.Single(Submits(await Get(url, "/__menus/state"), before))["params"]!;
        Assert.Equal(("Plan the weekend", mine.RowId), (sent.Str("text"), (long?)sent.Num("truncate_before_row_id")));
        await Until(() => !chat.Busy && chat.Messages.LastOrDefault()?.Role == Role.Assistant);
        await chat.RefreshAsync();
        Assert.DoesNotContain(chat.Messages, m => m.Role == Role.User && m.Text == "Plan the week");

        // Rewind to Here: the message itself again.
        mine = chat.Messages.Last(m => m.Role == Role.User);
        before = WalkProof.LastCallAt(await Get(url, "/__menus/state"));
        Assert.True(chat.Rewind(mine.Id, failures.Add));
        await chat.RewindSend!;
        sent = Assert.Single(Submits(await Get(url, "/__menus/state"), before))["params"]!;
        Assert.Equal(("Plan the weekend", mine.RowId), (sent.Str("text"), (long?)sent.Num("truncate_before_row_id")));
        await Until(() => !chat.Busy && chat.Messages.LastOrDefault()?.Role == Role.Assistant);

        Assert.Empty(failures);
    }
}
