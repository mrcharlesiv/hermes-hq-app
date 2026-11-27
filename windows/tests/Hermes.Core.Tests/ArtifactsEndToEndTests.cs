using System.Text.Json.Nodes;
using Hermes.Core.Artifacts;
using Hermes.Core.Auth;
using Hermes.Core.Net;
using Hermes.Core.Shell;

namespace Hermes.Core.Tests;

/// Artifacts against windows/ci/fixtures/artifacts-gateway.py (the pages fixture's chats plus linked notes): the pass
/// over every bot's recent chats, repeats, scopes, previews (a picture's data URL, a PDF, a page, code, a note), a file
/// that's gone, and a note's links to other notes. Run through windows/scripts/e2e.sh (HQW_E2E_ARTIFACTS_CREDENTIALS);
/// without it these pass vacuously.
[Trait("Category", "E2E")]
public class ArtifactsEndToEndTests
{
    private static async Task Until(Func<bool> condition, int seconds = 30)
    {
        var until = DateTime.UtcNow.AddSeconds(seconds);
        while (!condition())
        {
            if (DateTime.UtcNow > until) throw new TimeoutException("condition not met");
            await Task.Delay(50);
        }
    }

    [Fact]
    public async Task GridScopesPreviewsRepeatsAndLinkedNotes()
    {
        var path = Environment.GetEnvironmentVariable("HQW_E2E_ARTIFACTS_CREDENTIALS");
        if (path == null || !File.Exists(path)) return;
        var cred = JsonNode.Parse(File.ReadAllText(path))!;
        var url = cred.Str("url")!;
        using (var http = new HttpClient())
            (await http.PostAsync(url.TrimEnd('/') + "/__fixture/reset", new StringContent("{}"))).EnsureSuccessStatusCode();

        var signIn = new SignIn(new MemoryTokenStore());
        var session = await signIn.PasswordAsync(GatewayAddress.FromTyped(url), cred.Str("username")!, cred.Str("password")!);
        await using var client = new HermesClient(session);
        var bots = await client.BotsAsync();
        Assert.Contains(bots, b => b.Name == "research");
        var dir = Path.Combine(Path.GetTempPath(), "artifacts-e2e-" + Guid.NewGuid());
        try
        {
            var source = new GatewayArtifactSource(session);
            var store = new ArtifactsStore(source, Path.Combine(dir, "artifacts-index.json"), new ArtifactHidden(null))
            {
                ProfilesProvider = () => [.. bots.Select(b => b.Name)],
                DisplayName = p => bots.FirstOrDefault(b => b.Name == p)?.DisplayName ?? p,
            };
            var pass = store.RefreshAsync(explicit_: true);
            await Until(() => pass.IsCompleted, 60);
            await pass;
            Assert.Null(store.LoadError);
            var values = store.Artifacts.Select(a => a.Value).ToHashSet();
            foreach (var expected in new[] { "/home/hermes/reading/summary.md", "/home/hermes/reading/results.png", "https://example.org/papers/open-planning",
                         "/home/hermes/out/report.pdf", "/home/hermes/site/index.html", "/home/hermes/app/Sources/App.swift",
                         "/home/hermes/app/release-notes.md", "/home/hermes/data/export.csv", "/home/hermes/gone/old.png",
                         "/home/hermes/big/log.txt", "/home/hermes/app/notes/index.md", "/home/hermes/app/notes/plan.md", "https://example.com/a" })
                Assert.Contains(expected, values);
            Assert.DoesNotContain("./out/summary.md", values);   // a cron run without a folder
            Assert.DoesNotContain(values, v => v.Contains("example.co…"));
            // Repeats: plan.md three times in one chat and once in another is one row counting four; the link twice.
            Assert.Equal(4, store.Artifacts.Single(a => a.Value.EndsWith("/notes/plan.md")).Repeats);
            Assert.Equal("×2", store.Artifacts.Single(a => a.Value == "https://example.com/a").RepeatBadge);
            // Newest first, grouped by day.
            Assert.True(store.Artifacts.Zip(store.Artifacts.Skip(1)).All(p => p.First.Timestamp >= p.Second.Timestamp));
            Assert.NotEmpty(ArtifactListWords.DaysOf(store.Artifacts.Where(a => a.Kind != ArtifactKind.Image)));

            // A second visit reads only chats that changed (none).
            var second = store.RefreshAsync(explicit_: true);
            await Until(() => second.IsCompleted, 60);
            Assert.Equal(store.Artifacts.Count, values.Count);

            // Scopes: one bot's own.
            store.SetScope("research");
            Assert.All(store.Artifacts, a => Assert.Equal("research", a.Profile));
            var scoped = store.RefreshAsync(explicit_: true);
            await Until(() => scoped.IsCompleted, 60);
            Assert.Contains(store.Artifacts, a => a.Value == "/home/hermes/app/notes/index.md");
            Assert.DoesNotContain(store.Artifacts, a => a.Value == "/home/hermes/out/report.pdf");
            store.SetScope(ArtifactsStore.All);
            var all = store.RefreshAsync(explicit_: true);
            await Until(() => all.IsCompleted, 60);
            ArtifactRecord Find(string value) => store.Artifacts.Single(a => a.Value == value);

            // Previews: a picture through read-data-url, a PDF, a page, code and a note through download.
            var png = await ArtifactReads.ImageAsync(source, Find("/home/hermes/reading/results.png"));
            Assert.Equal(new byte[] { 0x89, 0x50, 0x4E, 0x47 }, png.Take(4));
            async Task<byte[]> Download(ArtifactRecord r)
            {
                var file = ArtifactFiles.PreviewPath(dir, r);
                await source.DownloadAsync(r, file, CancellationToken.None);
                return await File.ReadAllBytesAsync(file);
            }
            var pdf = Find("/home/hermes/out/report.pdf");
            Assert.Equal(ArtifactOpeningKind.Pdf, ArtifactFiles.Opening(pdf).Kind);
            Assert.StartsWith("%PDF", System.Text.Encoding.ASCII.GetString(await Download(pdf), 0, 4));
            var page = Find("/home/hermes/site/index.html");
            Assert.Equal(ArtifactOpeningKind.Html, ArtifactFiles.Opening(page).Kind);
            Assert.Contains("<h1>Release 2.4</h1>", System.Text.Encoding.UTF8.GetString(ArtifactFiles.PreviewHtml(await Download(page))!));
            var code = Find("/home/hermes/app/Sources/App.swift");
            Assert.Equal(new ArtifactOpening(ArtifactOpeningKind.Text, false, "swift"), ArtifactFiles.Opening(code));
            Assert.Contains("struct ReleaseApp", System.Text.Encoding.UTF8.GetString(await Download(code)));
            var big = await Download(Find("/home/hermes/big/log.txt"));
            Assert.False(ArtifactFiles.OpensAsText(ArtifactFiles.Opening(Find("/home/hermes/big/log.txt")), big.Length));

            // A file that's gone: 404, so it goes to Unavailable with the Mac's words.
            var gone = Find("/home/hermes/gone/old.png");
            var missing = await Assert.ThrowsAsync<GatewayException>(() => ArtifactReads.ImageAsync(source, gone));
            Assert.True(ArtifactFiles.IsMissing(missing));
            Assert.Equal("This file is no longer on the computer running Hermes. It may have been moved or deleted.", ArtifactFiles.FailureText(missing, true));
            store.MarkUnavailable(gone.Id);
            Assert.Contains(gone.Id, store.Unavailable);

            // Linked notes: index.md's links resolve in its folder and open with its chat.
            var index = Find("/home/hermes/app/notes/index.md");
            var text = System.Text.Encoding.UTF8.GetString(await Download(index));
            Assert.Contains("[the plan](plan.md)", text);
            Assert.Equal("usage", ArtifactLinks.Headings(text)[^1].Id);
            ArtifactRecord Linked(string target)
            {
                var link = ArtifactLinks.Classify(target);
                var notePath = ArtifactLinks.LinkedNotePath(index.Value, link.Target!);
                return index with { Value = notePath, Href = notePath, Label = ArtifactLinks.Name(notePath), Kind = ArtifactKind.File, Repeats = 1,
                    Id = index.Id + "\u001F" + notePath };
            }
            Assert.Contains("# Plan", System.Text.Encoding.UTF8.GetString(await Download(Linked("plan.md"))));
            Assert.Contains("# README", System.Text.Encoding.UTF8.GetString(await Download(Linked("../README.md"))));
            Assert.Contains("# Absolute", System.Text.Encoding.UTF8.GetString(await Download(Linked("/home/hermes/abs.md"))));
            var noNote = await Assert.ThrowsAsync<GatewayException>(() => Download(Linked("missing.md")));
            Assert.True(ArtifactFiles.IsMissing(noNote));
            Assert.Equal(ArtifactLinkKind.Hash, ArtifactLinks.Classify("#usage").Kind);
            Assert.Equal(ArtifactLinkKind.External, ArtifactLinks.Classify("https://example.com").Kind);

            // Remove: the row leaves the list and stays gone.
            store.Hidden.Hide(Find("/home/hermes/data/export.csv"));
            Assert.DoesNotContain(store.Artifacts, a => a.Value == "/home/hermes/data/export.csv");
        }
        finally { try { Directory.Delete(dir, true); } catch (IOException) { } }
    }

    /// [WIN-34] The files the file-windows walk opens in windows of their own (WalkProof.WalkPagePath, WalkNotePath),
    /// fetched as the walk fetches them: the release page and the notes' index, each from its own chat, each a file the
    /// window router puts in a page window (FileWindowRoute: Page, Note).
    [Fact]
    public async Task TheFileWindowsWalksFilesDownloadAndRouteToWindows()
    {
        var path = Environment.GetEnvironmentVariable("HQW_E2E_ARTIFACTS_CREDENTIALS");
        if (path == null || !File.Exists(path)) return;
        var cred = JsonNode.Parse(File.ReadAllText(path))!;
        var session = await new SignIn(new MemoryTokenStore()).PasswordAsync(GatewayAddress.FromTyped(cred.Str("url")!), cred.Str("username")!, cred.Str("password")!);
        var dir = Path.Combine(Path.GetTempPath(), "file-windows-e2e-" + Guid.NewGuid());
        Directory.CreateDirectory(dir);
        try
        {
            foreach (var (gatewayPath, name, sid, bot, shows) in new[]
                     {
                         (WalkProof.WalkPagePath, WalkProof.WalkPageName, WalkProof.WalkPageSession, WalkProof.WalkPageBot, FileWindowShows.Page),
                         (WalkProof.WalkNotePath, WalkProof.WalkNoteName, WalkProof.WalkNoteSession, WalkProof.WalkNoteBot, FileWindowShows.Note),
                     })
            {
                var file = Path.Combine(dir, name);
                await session.DownloadToFileAsync("/api/fs/download", [new("path", gatewayPath), new("session_id", sid), new("profile", bot)], file, ArtifactFiles.FileLimit);
                Assert.True(new FileInfo(file).Length > 0, $"{name} is empty");
                Assert.Equal(shows, FileWindowRoute.For(name, new FileInfo(file).Length));
            }
            // The heading the walk then reads off the live page (PageDrawnAsync): a document with words, not a blank.
            Assert.Contains($"<h1>{WalkProof.WalkPageHeading}</h1>", File.ReadAllText(Path.Combine(dir, WalkProof.WalkPageName)));
            Assert.StartsWith("# Project Notes", File.ReadAllText(Path.Combine(dir, WalkProof.WalkNoteName)));
        }
        finally { Directory.Delete(dir, true); }
    }
}
