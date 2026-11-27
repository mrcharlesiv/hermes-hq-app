using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Bots;
using Hermes.Core.Net;
using Hermes.Core.Sessions;
using Hermes.Core.Shell;

namespace Hermes.Core.Tests;

/// Archive Chat (Ctrl+Alt+A) against the composer stand-in, through the same call the sidebar's Archive makes
/// (`SessionStore.SetArchivedAsync`): the stand-in records the PATCH the chat-keys walk reads (`ChatKeys.ArchivedOverRest`),
/// Trip planning leaves the list, and Undo's unarchive brings it back. Run through windows/scripts/e2e.sh; without the
/// credentials it passes vacuously. It shares the composer stand-in's collection and leaves the chat unarchived.
[Collection(ComposerStandIn.Name)]
[Trait("Category", "E2E")]
public class ChatKeysEndToEndTests
{
    private static async Task<JsonNode> Get(string url, string path)
    {
        using var http = new HttpClient();
        return JsonNode.Parse(await http.GetStringAsync(url.TrimEnd('/') + path))!;
    }

    [Fact]
    public async Task ArchiveChatPatchesTheChatAndUndoBringsItBack()
    {
        var path = Environment.GetEnvironmentVariable("HQW_E2E_COMPOSER_CREDENTIALS");
        if (path == null || !File.Exists(path)) return;
        var cred = JsonNode.Parse(File.ReadAllText(path))!;
        var url = cred.Str("url")!;
        var session = await new SignIn(new MemoryTokenStore()).PasswordAsync(GatewayAddress.FromTyped(url), cred.Str("username")!, cred.Str("password")!);
        await using var client = new HermesClient(session);
        await client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(15)).Token);
        var sessions = new SessionStore(new ClientGateway(client), new MemoryDeviceStore());
        await sessions.RefreshAsync();
        var trip = sessions.LiveSummaries().Single(s => s.Id == WalkProof.TripStoredId);

        // The shell's facts with Trip planning open: a chat, online, not archived — Archive Chat acts.
        var state = new ChatKeyState(OpenPane.Chat, trip.Profile, trip.Id, Online: client.Rpc.State == Hermes.Core.Rpc.ConnectionState.Open,
            Archived: sessions.Row(trip.Profile, trip.Id)?.Archived == true);
        Assert.Equal(ArchiveStep.Archive, ChatKeys.Archive(state));

        var mark = ChatKeys.RestCount(await Get(url, "/__menus/state"));
        try
        {
            await sessions.SetArchivedAsync(trip, true);
            Assert.Null(ChatKeys.ArchivedOverRest(await Get(url, "/__menus/state"), mark, trip.Id, archived: true));
            Assert.DoesNotContain(sessions.LiveSummaries(), s => s.Id == trip.Id);
            await sessions.RefreshAsync();
            Assert.DoesNotContain(sessions.LiveSummaries(), s => s.Id == trip.Id);   // the stand-in no longer lists it
        }
        finally
        {
            var back = ChatKeys.RestCount(await Get(url, "/__menus/state"));
            await sessions.SetArchivedAsync(trip with { Archived = true }, false);   // Undo
            Assert.Null(ChatKeys.ArchivedOverRest(await Get(url, "/__menus/state"), back, trip.Id, archived: false));
        }
        await sessions.RefreshAsync();
        Assert.Contains(sessions.LiveSummaries(), s => s.Id == trip.Id);
    }
}
