using System.Text;
using System.Text.Json.Nodes;
using Hermes.Core.Attachments;
using Hermes.Core.Auth;
using Hermes.Core.Chat;
using Hermes.Core.Model;
using Hermes.Core.Net;

namespace Hermes.Core.Tests;

/// Photos and files against scripts/fixtures/attachments-gateway.py (spec 1x-attachments §14.2). Run through
/// windows/scripts/e2e-attachments.sh, which starts the fixture and sets HQW_E2E_ATTACH_CREDENTIALS; without it these
/// tests pass vacuously. One test at a time: they share the fixture's chat.
[Trait("Category", "E2E-Attachments")]
[Collection("attachments-e2e")]
public class AttachmentsEndToEndTests
{
    private static (string Url, string User, string Password)? Credentials()
    {
        var path = Environment.GetEnvironmentVariable("HQW_E2E_ATTACH_CREDENTIALS");
        if (path == null || !File.Exists(path)) return null;
        var j = JsonNode.Parse(File.ReadAllText(path))!;
        return (j.Str("url")!, j.Str("username")!, j.Str("password")!);
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

    private static readonly HttpClient Http = new();

    private static async Task<JsonNode> Post(string url, string path, object body)
    {
        var res = await Http.PostAsync(url.TrimEnd('/') + path, new StringContent(System.Text.Json.JsonSerializer.Serialize(body),
            Encoding.UTF8, "application/json"));
        res.EnsureSuccessStatusCode();
        return JsonNode.Parse(await res.Content.ReadAsStringAsync())!;
    }

    private static async Task<JsonNode> State(string url) =>
        JsonNode.Parse(await Http.GetStringAsync(url.TrimEnd('/') + "/__fixture/state"))!;

    private sealed record Rig(string Url, HermesClient Client, ChatSession Chat, AttachmentCenter Center, string Scope, string Folder)
        : IAsyncDisposable
    {
        public async ValueTask DisposeAsync()
        {
            Center.Dispose();
            await Chat.DisposeAsync();
            await Client.DisposeAsync();
        }
    }

    private static async Task<Rig?> Open()
    {
        if (Credentials() is not var (url, user, password)) return null;
        await Post(url, "/__fixture/attach-reset", new { });
        var session = await new SignIn(new MemoryTokenStore()).PasswordAsync(GatewayAddress.FromTyped(url), user, password);
        var client = new HermesClient(session);
        await client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(15)).Token);
        var bot = (await client.BotsAsync()).First(b => b.Name == "default");
        var chat = client.OpenChat(bot.Name, await client.BotChatIdAsync(bot), bot.DisplayName);
        await chat.OpenAsync();
        var folder = Directory.CreateTempSubdirectory("hq-attach-").FullName;
        InlineMediaStore.Root = Path.Combine(folder, "inline");
        var center = new AttachmentCenter(client, Path.Combine(folder, "account")) { AutoRetryDelay = TimeSpan.FromMilliseconds(200) };
        return new Rig(url, client, chat, center, chat.DraftScope, folder);
    }

    private static string MakeFile(string folder, string name, byte[] bytes)
    {
        var path = Path.Combine(folder, "picked", name);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllBytes(path, bytes);
        return path;
    }

    private static bool Uploaded(Rig r) => r.Center.GetDraft(r.Scope).Attachments.All(a => a.IsUploaded);

    [Fact]
    public async Task PhotoAndFileUploadAttachSendAndShowFromTheSeededCopy()
    {
        await using var r = await Open();
        if (r == null) return;
        var png = Pictures.Png(320, 200);
        var picks = new[]
        {
            new PickedItem(MakeFile(r.Folder, "Holiday.png", png), "Holiday.png", PickSource.Photo),
            new PickedItem(MakeFile(r.Folder, "My Report.pdf", Encoding.ASCII.GetBytes("%PDF-1.4 synthetic")), "My Report.pdf", PickSource.File),
        };
        Assert.Empty(await r.Center.AddPicksAsync(r.Scope, r.Chat.Profile, picks));
        var tray = r.Center.GetDraft(r.Scope).Attachments;
        Assert.Equal([DraftKind.Image, DraftKind.File], tray.Select(a => a.Kind));
        Assert.Equal(320, tray[0].PixelWidth);
        await Until(() => Uploaded(r));

        var state = await State(r.Url);
        var uploads = state.Arr("uploads")!;
        Assert.Equal(2, uploads.Count);
        Assert.All(uploads, u => Assert.StartsWith("/fixture/uploads/.dispatch-attachments/", u.Str("path")));
        Assert.Equal(["Holiday.png", "My Report.pdf"], uploads.Select(u => u.Str("filename")).Order());

        r.Center.SetText(r.Scope, r.Chat.Profile, "look");
        var (text, attachments) = r.Center.TakeForSend(r.Scope);
        Assert.Empty(r.Center.GetDraft(r.Scope).Attachments);
        await r.Chat.SendAsync(text, attachments, r.Center);
        await Until(() => !r.Chat.Busy && r.Chat.Messages.Any(m => m.Text.Contains("Received 1 image(s) and 1 file(s).")));

        state = await State(r.Url);
        var prompt = state.Arr("prompts")!.Last()!;
        Assert.Equal("@file:`/fixture-home/attachments/My Report.pdf`\n\nlook", prompt.Str("text"));
        var photoPath = Assert.Single(prompt.Arr("images")!)!.GetValue<string>();
        var ledger = state.Arr("attachLedger")!.Select(e => e.Str("method")).Where(m => m != "session.resume").ToList();
        Assert.Equal(["image.attach", "file.attach", "prompt.submit"], ledger);
        foreach (var e in state.Arr("attachLedger")!.Where(e => e.Str("method") is "image.attach" or "file.attach"))
            Assert.Null(e.Get("error"));
        // The file's staging folder goes once the gateway copied it out; the photo's never does.
        await Until(() => State(r.Url).Result.Arr("deletes")!.Count == 1);
        var deleted = (await State(r.Url)).Arr("deletes")![0]!;
        Assert.Equal(200, deleted.Int("status"));
        Assert.False(photoPath.StartsWith(deleted.Str("path")!));

        // The stored row: the photo by its gateway path, served from the seeded copy (no download).
        await Until(() => r.Chat.Messages.Any(m => m.Role == Role.User && !m.Id.StartsWith("local-") && m.Attachments.Any()));
        var mine = r.Chat.Messages.Last(m => m.Role == Role.User);
        Assert.Equal("look", mine.Text);
        var photo = mine.Attachments.First(a => a.IsImage);
        Assert.Equal(new AttachmentSource.Gateway(photoPath), photo.Source);
        Assert.Contains(mine.Attachments, a => a.Kind == AttachmentKind.File && a.Name == "My Report.pdf");
        var shown = await r.Center.Media.ImageAsync(photo, r.Chat.Profile, r.Chat.MediaSessionId);
        Assert.Equal(png, File.ReadAllBytes(shown));
        Assert.DoesNotContain((await State(r.Url)).Arr("downloads")!, d => d.Str("path") == photoPath);
    }

    [Fact]
    public async Task HistoryPicturesFilesAndGeneratedImagesLoad()
    {
        await using var r = await Open();
        if (r == null) return;
        await Post(r.Url, "/__fixture/attachments-history", new { profile = "default" });
        await r.Chat.RefreshAsync();
        var messages = r.Chat.Messages;
        var chart = messages.First(m => m.Text == "Here is the chart");
        var chartAtt = Assert.Single(chart.Attachments);
        Assert.Equal("chart.png", chartAtt.Name);
        Assert.Contains(messages, m => m.Text == "what is this?" && m.Attachments.Single().Source is AttachmentSource.Inline);
        Assert.Contains(messages, m => m.Text == "Please summarise this" && m.Attachments.Single().Name == "report.pdf");
        Assert.Contains(messages, m => m.Parts.OfType<GeneratedImagePart>().Any(g => g.Image.Source == "/fixture/media/fox.png"));
        Assert.Contains(messages, m => m.Role == Role.Assistant && m.Attachments.Any(a => a.Name == "result.png"));

        var file = await r.Center.Media.ImageAsync(chartAtt, r.Chat.Profile, r.Chat.MediaSessionId);
        Assert.NotNull(ImageHeader.PixelSizeOfFile(file));
        var download = (await State(r.Url)).Arr("downloads")!.Last()!;
        Assert.Equal("/fixture/media/chart.png", download.Str("path"));
        Assert.Equal("default", download.Str("profile"));
        Assert.Null(download.Str("session_id")); // absolute path: no session_id

        var missing = messages.SelectMany(m => m.Attachments).First(a => a.Name == "missing.png");
        var e = await Assert.ThrowsAsync<MediaLoadException>(() => r.Center.Media.ImageAsync(missing, r.Chat.Profile, r.Chat.MediaSessionId));
        Assert.Equal(MediaLoadException.Kinds.NotFound, e.Kind);

        var pdf = await r.Center.Media.GatewayFileAsync("/fixture-home/attachments/report.pdf", "report.pdf", r.Chat.Profile, r.Chat.MediaSessionId);
        Assert.Equal("report.pdf", Path.GetFileName(pdf));
        Assert.StartsWith("%PDF", File.ReadAllText(pdf));
        // Opened under a label (desktop_preview's label, a pin's title): kept with the file's own type.
        var labelled = await r.Center.Media.GatewayFileAsync("/fixture-home/attachments/report.pdf", "Quarterly report", r.Chat.Profile, r.Chat.MediaSessionId);
        Assert.Equal("Quarterly report.pdf", Path.GetFileName(labelled));
        Assert.Equal(labelled, r.Center.Media.CachedFile(r.Chat.Profile, "/fixture-home/attachments/report.pdf", "Quarterly report"));
    }

    [Fact]
    public async Task UploadFailuresRetryOnceThenTryAgain()
    {
        await using var r = await Open();
        if (r == null) return;
        await Post(r.Url, "/__fixture/attach-control", new { uploadFailures = 2 });
        await r.Center.AddPicksAsync(r.Scope, r.Chat.Profile,
            [new PickedItem(MakeFile(r.Folder, "notes.txt", "hello"u8.ToArray()), "notes.txt", PickSource.File)]);
        await Until(() => r.Center.GetDraft(r.Scope).Attachments.Single().Upload is UploadState.Failed);
        var failed = r.Center.GetDraft(r.Scope).Attachments.Single();
        Assert.Equal("Couldn’t upload “notes.txt” (gateway error 500).", failed.Failure!.Reason);
        Assert.True(failed.OffersRetry);
        r.Center.Retry(failed.Id);
        await Until(() => Uploaded(r));

        // Too big for the gateway: final, no Try Again.
        await Post(r.Url, "/__fixture/attach-control", new { maxBytes = 3 });
        await r.Center.AddPicksAsync(r.Scope, r.Chat.Profile,
            [new PickedItem(MakeFile(r.Folder, "big.txt", "too big"u8.ToArray()), "big.txt", PickSource.File)]);
        await Until(() => r.Center.GetDraft(r.Scope).Attachments.Last().Upload is UploadState.Failed);
        var big = r.Center.GetDraft(r.Scope).Attachments.Last();
        Assert.Equal("“big.txt” is too big for your gateway.", big.Failure!.Reason);
        Assert.False(big.OffersRetry);

        // ✕ on an uploaded tile deletes its staging folder on the gateway.
        var done = r.Center.GetDraft(r.Scope).Attachments.First();
        r.Center.Remove(done.Id, r.Scope);
        await Until(() => State(r.Url).Result.Arr("deletes")!.Any(d => d.Str("path") == done.StagingFolder && d.Int("status") == 200));
    }

    [Fact]
    public async Task StopWhileUploadingHandsTheDraftBack()
    {
        await using var r = await Open();
        if (r == null) return;
        await Post(r.Url, "/__fixture/attach-control", new { uploadDelay = 2.0 });
        await r.Center.AddPicksAsync(r.Scope, r.Chat.Profile,
            [new PickedItem(MakeFile(r.Folder, "slow.png", Pictures.Png(8, 8)), "slow.png", PickSource.Photo)]);
        r.Center.SetText(r.Scope, r.Chat.Profile, "wait for it");
        var (text, attachments) = r.Center.TakeForSend(r.Scope);
        string? returned = "not yet";
        r.Chat.SendReturned += why => returned = why;
        var sending = r.Chat.SendAsync(text, attachments, r.Center);
        await Until(() => r.Chat.Busy);
        await r.Chat.StopAsync();
        await sending;
        Assert.Null(returned);
        var draft = r.Center.GetDraft(r.Scope);
        Assert.Equal("wait for it", draft.Text);
        Assert.Equal(attachments[0].Id, Assert.Single(draft.Attachments).Id);
        Assert.DoesNotContain(r.Chat.Messages, m => m.Id.StartsWith("local-user"));
        await Until(() => Uploaded(r)); // the upload itself kept going
        Assert.Empty((await State(r.Url)).Arr("prompts")!);
    }

    /// [WIN-ATTACH-REFUSE-CARD] AttachmentPipelineTests refusalReturnsUploadedAttachments on the fixture: image.attach
    /// answers {} → the one "Couldn’t Send" card says why, no error row in the transcript, nothing submitted, and the
    /// words and the uploaded photo come back to the draft.
    [Fact]
    public async Task ARefusedAttachIsTheCouldntSendCardAndTheDraftComesBack()
    {
        await using var r = await Open();
        if (r == null) return;
        await r.Center.AddPicksAsync(r.Scope, r.Chat.Profile,
            [new PickedItem(MakeFile(r.Folder, "refused.png", Pictures.Png(4, 4)), "refused.png", PickSource.Photo)]);
        await Until(() => Uploaded(r));
        var name = r.Center.GetDraft(r.Scope).Attachments.Single().Name;
        await Post(r.Url, "/__fixture/attach-control", new { imageAttach = "empty" });
        r.Center.SetText(r.Scope, r.Chat.Profile, "look");
        var (text, attachments) = r.Center.TakeForSend(r.Scope);
        string? returned = "not yet";
        r.Chat.SendReturned += why => returned = why;
        await r.Chat.SendAsync(text, attachments, r.Center);
        var reason = $"Your gateway didn’t accept “{name}”.";
        Assert.Equal(reason, returned);
        Assert.Equal(reason, r.Chat.SendFailure?.Reason);
        Assert.DoesNotContain(r.Chat.Messages, m => m.Role == Role.System && m.Error != null);
        Assert.DoesNotContain(r.Chat.Messages, m => m.Id.StartsWith("local-user"));
        var draft = r.Center.GetDraft(r.Scope);
        Assert.Equal("look", draft.Text);
        Assert.True(Assert.Single(draft.Attachments).IsUploaded);
        Assert.Empty((await State(r.Url)).Arr("prompts")!);
    }

    [Fact]
    public async Task AStaleRuntimeOnAttachResumesOnceAndAttachesAgain()
    {
        await using var r = await Open();
        if (r == null) return;
        await r.Center.AddPicksAsync(r.Scope, r.Chat.Profile,
            [new PickedItem(MakeFile(r.Folder, "a.png", Pictures.Png(4, 4)), "a.png", PickSource.Photo)]);
        await Until(() => Uploaded(r));
        await Post(r.Url, "/__fixture/attach-control", new { imageAttach = "stale-once" });
        var (text, attachments) = r.Center.TakeForSend(r.Scope);
        await r.Chat.SendAsync(text, attachments, r.Center);
        await Until(() => !r.Chat.Busy && r.Chat.Messages.Any(m => m.Text.Contains("Received 1 image(s)")));
        var state = await State(r.Url);
        Assert.Equal("What do you see in this image?", state.Arr("prompts")!.Last()!.Str("text"));
        var attaches = state.Arr("attachLedger")!.Where(e => e.Str("method") == "image.attach").ToList();
        Assert.Equal(2, attaches.Count);
        Assert.Equal(4001, attaches[0]!.Int("error"));
        Assert.Null(attaches[1]!.Get("error"));
    }

    [Fact]
    public async Task AStaleRuntimeOnSubmitReattachesThePhotosOnly()
    {
        await using var r = await Open();
        if (r == null) return;
        await r.Center.AddPicksAsync(r.Scope, r.Chat.Profile,
        [
            new PickedItem(MakeFile(r.Folder, "b.png", Pictures.Png(6, 6)), "b.png", PickSource.Photo),
            new PickedItem(MakeFile(r.Folder, "c.txt", "c"u8.ToArray()), "c.txt", PickSource.File),
        ]);
        await Until(() => Uploaded(r));
        await Post(r.Url, "/__fixture/attach-control", new { submitStaleOnce = true });
        var (_, attachments) = r.Center.TakeForSend(r.Scope);
        await r.Chat.SendAsync("both", attachments, r.Center);
        await Until(() => !r.Chat.Busy && r.Chat.Messages.Any(m => m.Text.Contains("Received 1 image(s) and 1 file(s).")));
        var methods = (await State(r.Url)).Arr("attachLedger")!.Select(e => e.Str("method") + (e.Get("error") != null ? "!" : ""))
            .Where(m => m != "session.resume").ToList();
        Assert.Equal(["image.attach", "file.attach", "prompt.submit!", "image.attach", "prompt.submit"], methods);
    }
}
