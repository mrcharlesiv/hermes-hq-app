using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Chat;
using Hermes.Core.Model;
using Hermes.Core.Net;
using Hermes.Core.Shell;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Tests;

/// [WIN-36] The transcript-extras walk's chat on composer-gateway.py (“Release review”), opened and driven through the
/// same Hermes.Core paths the app takes: its history folds into a link chip's reply, a wide table, a model-change note,
/// a job's delivery and two changed files; the link's title is read from the stand-in on loopback through the walk's
/// reader; a send fails with a usage limit (a Choose a Model card) and another is refused (“Couldn’t Send”). Run through
/// windows/scripts/e2e.sh; without the credentials it passes vacuously.
[Collection(ComposerStandIn.Name)]
[Trait("Category", "E2E")]
public class TranscriptExtrasWalkEndToEndTests
{
    private static async Task<JsonNode> Get(string url, string path)
    {
        using var http = new HttpClient();
        return JsonNode.Parse(await http.GetStringAsync(url.TrimEnd('/') + path))!;
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

    [Fact]
    public async Task TheExtrasChatShowsEveryExtraAndItsSendsFailAsTheWalkExpects()
    {
        var path = Environment.GetEnvironmentVariable("HQW_E2E_COMPOSER_CREDENTIALS");
        if (path == null || !File.Exists(path)) return;
        var cred = JsonNode.Parse(File.ReadAllText(path))!;
        var url = cred.Str("url")!;
        var session = await new SignIn(new MemoryTokenStore()).PasswordAsync(GatewayAddress.FromTyped(url), cred.Str("username")!, cred.Str("password")!);
        await using var client = new HermesClient(session);
        await client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(15)).Token);

        // Never listed: the other walks' lists don't change.
        var listed = await client.Session.GetJsonAsync("/api/profiles/sessions/sidebar");
        Assert.DoesNotContain(WalkProof.ExtrasStoredId, listed.ToJsonString());

        await using var chat = client.OpenChat(WalkProof.ExtrasBot, WalkProof.ExtrasStoredId, WalkProof.ExtrasTitle);
        await chat.OpenAsync();
        await Until(() => chat.Messages.Count >= 6);
        var messages = chat.Messages;

        // The lone address is a chip of a settled reply.
        var linkReply = messages.Single(m => m.Role == Role.Assistant && m.Text.Contains(WalkProof.ExtrasLink));
        Assert.Contains(LinkChips.Split(linkReply.Text, settled: true), s => s is ChipSegment c && c.Raw == WalkProof.ExtrasLink);
        // The model-change note, the job's delivery, the table and the edited files.
        Assert.Contains(messages, m => m.Role == Role.System && TimelineNotes.Note(m.Text).Text == "Model changed to " + Hermes.Core.Composer.ModelNames.DisplayModelName("claude-sonnet-5"));
        Assert.Contains(messages, m => m.Role == Role.Assistant && CronDeliveries.Parse(m.Text)?.Job == WalkProof.ExtrasJob);
        Assert.Contains(messages, m => m.Role == Role.Assistant && m.Text.Contains("| Build | Platform |"));
        Assert.Contains(messages, m => m.Role == Role.Assistant && ChangedFiles.Derive(m.Tools).Count == WalkProof.ExtrasFilesChanged);

        // The chip's title, read from the stand-in on loopback through the walk's reader.
        var previews = new LinkPreviews(LinkPreviewFetcher.LoopbackStandIn(new Uri(url)));
        var preview = await previews.PreviewAsync(WalkProof.ExtrasLink);
        Assert.Equal(WalkProof.ExtrasLinkTitle, preview?.Title);
        Assert.NotNull(preview!.Icon);
        var face = LinkChips.Face(WalkProof.ExtrasLink, new Uri(WalkProof.ExtrasLink), preview);
        Assert.Null(WalkProof.ChipShowsFetched(face.AccessibleName, await Get(url, "/__extras/state")));

        // A send that fails with a usage limit: the error card offers Choose a Model.
        var mark = WalkProof.ExtrasSendCount(await Get(url, "/__extras/state"));
        Assert.Equal(SendOutcome.Accepted, await chat.SendAsync(WalkProof.ExtrasLimitWords));
        await Until(() => chat.Messages.Any(m => m.Role == Role.System && m.Error != null) && !chat.Busy);
        var failed = chat.Messages.Last(m => m.Role == Role.System && m.Error != null);
        var card = ErrorCard.Make(failed.Error!, "Hermes", retry: true, failed.Timestamp);
        Assert.Null(WalkProof.LimitCardReads(card.Title, card.ChooseModel ? ["Choose a Model", "Copy Details"] : ["Try Again", "Copy Details"]));

        // A send the stand-in refuses: “Couldn’t Send” with the refusal in one sentence.
        Assert.Equal(SendOutcome.Refused, await chat.SendAsync(WalkProof.ExtrasRefused));
        // [WIN-SEND-FAILURE-ONE-CARD] The card reads the session's one SendFailure.
        var refused = Assert.IsType<SendFailure>(chat.SendFailure);
        Assert.Null(WalkProof.CouldntSendReads(SendFailure.Title, refused.Body));
        // [WIN-SEND-REFUSE-WITHDRAW] Its bubble left the transcript (the words went back to the box).
        Assert.DoesNotContain(chat.Messages, m => m.Role == Role.User && m.Text == WalkProof.ExtrasRefused);
        Assert.Null(WalkProof.ExtrasSent(await Get(url, "/__extras/state"), mark, [WalkProof.ExtrasLimitWords, WalkProof.ExtrasRefused]));
    }
}
