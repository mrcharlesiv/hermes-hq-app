// [WIN-ROWS-STEP-WALK] The row-steps walk's stand-in over the real wire: windows/ci/fixtures/settings-gateway.py (its own
// instance) holds each turn on the step POST /__settings/hold names until /__settings/release, and slows one bot's
// session.resume (/__settings/fail mode slow with seconds and profile). A signed-in HermesClient's chats and the app's
// TurnRows (the socket's frames → each chat's step, Hermes.Core/Chat/TurnRows.cs) see: ivy's Bot Chat on
// "reading package.json" and its side chat Trip ideas on "running npm test", each its own, while both turns hold; the
// release ends both and the steps go; Research's chat takes the armed seconds to open, once, and ivy's doesn't.
// Run through windows/scripts/e2e.sh (HQW_E2E_ROWSTEPS_CREDENTIALS); without it this passes vacuously.

using System.Diagnostics;
using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Chat;
using Hermes.Core.Net;
using Proof = Hermes.Core.Shell.RowStepsWalkProof;

namespace Hermes.Core.Tests;

[Trait("Category", "E2E")]
public sealed class RowStepsEndToEndTests
{
    private static async Task<JsonNode> State(string url)
    {
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
        return JsonNode.Parse(await http.GetStringAsync(url.TrimEnd('/') + Proof.StatePath))!;
    }

    private static async Task<HttpResponseMessage> Post(string url, string path, string body)
    {
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
        return await http.PostAsync(url.TrimEnd('/') + path, new StringContent(body, System.Text.Encoding.UTF8, "application/json"));
    }

    private static async Task<string?> Until(Func<Task<string?>> check, int seconds = 15)
    {
        var until = DateTime.UtcNow.AddSeconds(Math.Max(10, seconds));
        string? last;
        while ((last = await check()) != null && DateTime.UtcNow < until) await Task.Delay(100);
        return last;
    }

    [Fact]
    public async Task HeldTurnsNameEachChatsStepUntilReleasedAndOneBotsOpenIsSlow()
    {
        var path = Environment.GetEnvironmentVariable("HQW_E2E_ROWSTEPS_CREDENTIALS");
        if (path == null || !File.Exists(path)) return;
        var cred = JsonNode.Parse(File.ReadAllText(path))!;
        var url = cred.Str("url")!;
        var session = await new SignIn(new MemoryTokenStore()).PasswordAsync(GatewayAddress.FromTyped(url), cred.Str("username")!, cred.Str("password")!);
        await using var client = new HermesClient(session);
        await client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(30)).Token);
        var rows = new TurnRows { Roster = () => [] };
        rows.UseSocket(client.Rpc);

        // A hold the stand-in refuses: anything but {steps: [{name, args}]}.
        Assert.Equal(400, (int)(await Post(url, Proof.HoldPath, """{"steps":[{"name":"read_file"}]}""")).StatusCode);
        Assert.Equal(400, (int)(await Post(url, Proof.FailPath, """{"method":"session.resume","mode":"slow","seconds":90}""")).StatusCode);
        Assert.True((await Post(url, Proof.HoldPath, Proof.HoldBody())).IsSuccessStatusCode);

        var bots = await client.BotsAsync();
        var ivy = bots.Single(b => b.Name == Proof.Bot);
        var botChatId = await client.BotChatIdAsync(ivy);
        var listed = await client.Rpc.RequestAsync("session.list", new JsonObject { ["profile"] = Proof.Bot }, TimeSpan.FromSeconds(10));
        var sideId = listed["sessions"]!.AsArray().Single(s => s!["title"]!.GetValue<string>() == Proof.SideTitle)!["id"]!.GetValue<string>();
        await using var botChat = client.OpenChat(ivy.Name, botChatId, ivy.DisplayName);
        await botChat.OpenAsync();
        await using var side = client.OpenChat(ivy.Name, sideId, Proof.SideTitle);
        await side.OpenAsync();

        // Both turns hold on their own step: the Bot Chat reads package.json, the side chat runs npm test.
        Assert.Equal(SendOutcome.Accepted, await botChat.SendAsync(Proof.BotText));
        Assert.Equal(SendOutcome.Accepted, await side.SendAsync(Proof.SideText));
        Assert.Null(await Until(async () => Proof.Held(await State(url), 2)));
        Assert.Null(Proof.Prompts(await State(url), botChatId, sideId));
        string? Steps() =>
            rows.StepsByRuntime.GetValueOrDefault(botChat.RuntimeId!) is var b && b != "reading package.json" ? $"the Bot Chat's step is \"{b}\""
            : rows.StepsByRuntime.GetValueOrDefault(side.RuntimeId!) is var s && s != "running npm test" ? $"the side chat's step is \"{s}\""
            : null;
        Assert.Null(await Until(() => Task.FromResult(Steps())));
        Assert.Equal(Proof.BotLine, LiveStepsLine(rows, botChat));
        Assert.Equal(Proof.SideLine, LiveStepsLine(rows, side));
        // Still holding a moment later: no reply, both busy, the steps unchanged.
        await Task.Delay(1500);
        Assert.Null(Steps());
        Assert.True(botChat.Busy && side.Busy);
        Assert.Null(Proof.Held(await State(url), 2));

        // The release: each step completes, the reply writes, the turn ends; the steps go.
        Assert.True((await Post(url, Proof.ReleasePath, Proof.ReleaseBody())).IsSuccessStatusCode);
        Assert.Null(await Until(async () => botChat.Busy || side.Busy ? "a turn still runs"
            : rows.StepsByRuntime.Count > 0 ? $"steps left: {string.Join(", ", rows.StepsByRuntime.Values)}"
            : Proof.Held(await State(url), 0)));
        Assert.Contains(botChat.Messages, m => m.Text == "Hi! I'm Ivy.");
        Assert.Contains(side.Messages, m => m.Text == "Hi! I'm Ivy.");
        // [WIN-STEPS-AFTER-REPLY] The turn-end read brings the stored turn with its step (the stand-in saves the tool rows,
        // as Hermes does): the inspector's Steps (LatestSteps) keeps each finished reply's step, from a stored row.
        string? Kept(Hermes.Core.Chat.ChatSession chat, string name) =>
            Hermes.Core.Transcripts.LatestSteps.Of(chat.Messages) is [var only] && only.Call.Name == name
                && only.Call.State == Hermes.Core.Model.ToolState.Done && only.Message.Id.StartsWith("stored-row-", StringComparison.Ordinal)
                ? null : $"{chat.Title}: steps {string.Join(", ", Hermes.Core.Transcripts.LatestSteps.Of(chat.Messages).Select(s => $"{s.Message.Id}/{s.Call.Name}/{s.Call.State}"))}";
        Assert.Null(await Until(() => Task.FromResult(Kept(botChat, "read_file") ?? Kept(side, "terminal"))));

        // Research's open is slow (its resume only); ivy's chat opened after the arming isn't, and doesn't take it.
        Assert.True((await Post(url, Proof.FailPath, Proof.SlowOpenBody())).IsSuccessStatusCode);
        await using (var again = client.OpenChat(ivy.Name, botChatId, ivy.DisplayName))
        {
            var quick = Stopwatch.StartNew();
            await again.OpenAsync();
            Assert.True(quick.Elapsed < TimeSpan.FromSeconds(Proof.SlowOpenSeconds - 1), $"ivy's open took {quick.Elapsed}");
        }
        Assert.NotNull(Proof.SlowOpenTaken(await State(url)));
        var research = bots.Single(b => b.Name == Proof.WakingBot);
        var researchId = await client.BotChatIdAsync(research);
        await using (var slow = client.OpenChat(research.Name, researchId, research.DisplayName))
        {
            var timed = Stopwatch.StartNew();
            await slow.OpenAsync();
            Assert.True(timed.Elapsed >= TimeSpan.FromSeconds(Proof.SlowOpenSeconds - 0.25), $"Research's open took {timed.Elapsed}");
            Assert.NotNull(slow.RuntimeId);
        }
        Assert.Null(Proof.SlowOpenTaken(await State(url)));
        await using (var second = client.OpenChat(research.Name, researchId, research.DisplayName))
        {
            var quick = Stopwatch.StartNew();
            await second.OpenAsync();
            Assert.True(quick.Elapsed < TimeSpan.FromSeconds(Proof.SlowOpenSeconds - 1), $"Research's second open took {quick.Elapsed}");
        }
        rows.UseSocket(null);
    }

    private static string LiveStepsLine(TurnRows rows, ChatSession chat) =>
        Hermes.Core.Activity.LiveSteps.Line(rows.StepsByRuntime[chat.RuntimeId!]);
}
