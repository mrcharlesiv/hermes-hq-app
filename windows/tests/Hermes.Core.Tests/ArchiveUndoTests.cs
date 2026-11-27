using System.Text.Json.Nodes;
using Hermes.Core.Bots;
using Hermes.Core.Net;
using Hermes.Core.Sessions;
using Xunit;

namespace Hermes.Core.Tests;

/// [WIN-ARCHIVE-UNDO] Undo after an archive brings back exactly the chat that was archived (App/Sessions/
/// SessionsOrganizer.swift `archive(_:)`, App/Kit/UndoPill.swift `undo()` at 93f984bb1), driven through the same objects
/// the Windows pill and both archive routes use (`UndoPillPress`, `ArchiveUndo`, `SessionStore.SetArchivedAsync`)
/// against an in-memory stand-in gateway that keeps its own archived flags and logs every write. Synthetic chats only.
public class ArchiveUndoTests
{
    /// A stand-in gateway: the sidebar read lists what is not archived, the mutation snapshot answers a revision, and
    /// PATCH /api/sessions/{id}?profile=p sets that one row's flags. Every write is logged; a write can be held in
    /// flight, made to fail with an answer (500), or applied with its answer lost (a timeout), and a request id it has
    /// already applied is not applied twice.
    private sealed class StandIn : IListsGateway
    {
        public sealed class Chat
        {
            public required string Profile;
            public required string Id;
            public required string Title;
            public bool Archived;
            public bool Pinned;
            public int Changes;
        }

        public string AccountId { get; } = "archive-undo-" + Guid.NewGuid().ToString("N");
        public List<Chat> Chats { get; } = [];
        public List<(string Path, string Query, JsonObject Body)> Patches { get; } = [];
        private readonly HashSet<string> _applied = [];
        public int FailNext;
        public int LoseNextAnswer;
        public TaskCompletionSource? Hold;

        public Task<JsonNode> CallAsync(string method, JsonObject parameters, TimeSpan timeout, CancellationToken ct = default) =>
            throw new GatewayException("rpc", $"no handler for {method}", rpcCode: -32601);

        public async Task<RestAnswer> RestAsync(HttpMethod method, string path, IEnumerable<KeyValuePair<string, string>>? query = null,
            JsonNode? body = null, CancellationToken ct = default)
        {
            var q = (query ?? []).ToList();
            var profile = q.FirstOrDefault(kv => kv.Key == "profile").Value;
            if (method == HttpMethod.Get && path == "/api/profiles/sessions/sidebar")
            {
                var rows = new JsonArray();
                lock (Chats)
                    foreach (var c in Chats.Where(c => !c.Archived))
                        rows.Add(new JsonObject
                        {
                            ["id"] = c.Id, ["profile"] = c.Profile, ["profile_name"] = c.Profile, ["title"] = c.Title, ["archived"] = false,
                            ["pinned"] = c.Pinned, ["source"] = "desktop", ["message_count"] = 2, ["started_at"] = 1_700_000_000,
                            ["last_active"] = 1_700_000_100, ["preview"] = "synthetic", ["unread"] = false,
                        });
                return new RestAnswer(200, new JsonObject
                {
                    ["recents"] = new JsonObject { ["sessions"] = rows },
                    ["cron"] = new JsonObject { ["sessions"] = new JsonArray() },
                    ["messaging"] = new JsonObject { ["sessions"] = new JsonArray() },
                }.ToJsonString());
            }
            if (method == HttpMethod.Get && path.EndsWith("/mutation-snapshot", StringComparison.Ordinal))
                return new RestAnswer(200, """{"exists":true,"runtime_revision":3,"runtime_generation":1}""");
            if (method == HttpMethod.Patch && path.StartsWith("/api/sessions/", StringComparison.Ordinal))
            {
                var id = Uri.UnescapeDataString(path["/api/sessions/".Length..]);
                var sent = (JsonObject)body!.DeepClone();
                lock (Patches) Patches.Add((path, string.Join("&", q.Select(kv => kv.Key + "=" + kv.Value)), sent));
                if (Hold is { } hold) await hold.Task;
                if (FailNext > 0) { FailNext--; return new RestAnswer(500, """{"detail":"The stand-in refused this write."}"""); }
                lock (Chats)
                {
                    var requestId = sent["request_id"]?.GetValue<string>();
                    if (requestId == null || _applied.Add(requestId))
                    {
                        var chat = Chats.Single(c => c.Id == id && c.Profile == profile);
                        if (sent["archived"] is JsonValue a && a.TryGetValue(out bool archived)) { chat.Archived = archived; chat.Changes++; }
                    }
                }
                if (LoseNextAnswer > 0) { LoseNextAnswer--; throw new GatewayException("timeout", "timed out"); }
                return new RestAnswer(200, """{"ok":true}""");
            }
            return new RestAnswer(404, """{"detail":"Not Found"}""");
        }

        public int UnarchiveWrites() { lock (Patches) return Patches.Count(p => p.Body["archived"]?.GetValue<bool>() == false); }
    }

    /// Two chats share one stored id under different bots, and a third sits beside them: only otto's "s-100" may move.
    private static async Task<(StandIn Gw, SessionStore Store, SessionSummary Trip)> Make()
    {
        var gw = new StandIn();
        gw.Chats.Add(new StandIn.Chat { Profile = "otto", Id = "s-100", Title = "Trip planning" });
        gw.Chats.Add(new StandIn.Chat { Profile = "herald", Id = "s-100", Title = "Garden list", Pinned = true });
        gw.Chats.Add(new StandIn.Chat { Profile = "otto", Id = "s-200", Title = "Budget draft" });
        var store = new SessionStore(gw, new MemoryDeviceStore());
        await store.RefreshAsync();
        Assert.Null(store.Failure);
        var trip = store.LiveSummaries().Single(s => s.Profile == "otto" && s.Id == "s-100");
        return (gw, store, trip);
    }

    private static List<string> Keys(IEnumerable<SessionSummary> rows) => rows.Select(s => s.Profile + "/" + s.Id).OrderBy(k => k).ToList();

    private static void Untouched(StandIn gw)
    {
        Assert.All(gw.Chats.Where(c => !(c.Profile == "otto" && c.Id == "s-100")), c => { Assert.False(c.Archived); Assert.Equal(0, c.Changes); });
        Assert.All(gw.Patches, p => { Assert.Equal("/api/sessions/s-100", p.Path); Assert.Equal("profile=otto", p.Query); Assert.Equal("otto", p.Body["profile"]!.GetValue<string>()); });
    }

    /// Archive one chat, press the pill's Undo once: the same bot's same chat is back after a fresh read, with its title,
    /// and no other row was written or moved.
    [Fact]
    public async Task OneUndoBringsBackTheSameChatAfterARefresh()
    {
        var (gw, store, trip) = await Make();
        var before = Keys(store.LiveSummaries());

        await store.SetArchivedAsync(trip, true);                       // the route's archive (both routes wait for it)
        await store.RefreshAsync();
        Assert.DoesNotContain("otto/s-100", Keys(store.LiveSummaries()));
        Assert.Contains("herald/s-100", Keys(store.LiveSummaries()));   // the same id under another bot stays

        var undo = new ArchiveUndo(store, trip);
        Task? write = null;
        var dismissed = 0;
        var press = new UndoPillPress(() => dismissed++, () => write = undo.RestoreAsync());
        Assert.True(press.Press());
        await write!;
        await store.RefreshAsync();

        Assert.Equal(before, Keys(store.LiveSummaries()));
        var back = store.LiveSummaries().Single(s => s.Profile == "otto" && s.Id == "s-100");
        Assert.Equal("Trip planning", back.Title);
        Assert.False(back.Archived);
        Assert.True(store.LiveSummaries().Single(s => s.Profile == "herald").Pinned);
        Assert.Equal(1, dismissed);
        Assert.Equal(1, gw.UnarchiveWrites());
        Assert.Equal(2, gw.Patches.Count);
        Assert.Equal(1, undo.Writes);
        Assert.True(undo.Restored);
        Untouched(gw);
    }

    /// Two rapid clicks while the unarchive is still on its way: one write. A third, after it landed: still one.
    [Fact]
    public async Task TwoRapidClicksSendOneUnarchive()
    {
        var (gw, store, trip) = await Make();
        await store.SetArchivedAsync(trip, true);
        var undo = new ArchiveUndo(store, trip);
        var writes = new List<Task>();
        var press = new UndoPillPress(() => { }, () => writes.Add(undo.RestoreAsync()));
        gw.Hold = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

        Assert.True(press.Press());
        Assert.False(press.Press());                                    // the second click finds the pill taken
        Assert.Single(writes);
        var joined = undo.RestoreAsync();                               // and the undo itself joins the one on its way
        Assert.Same(writes[0], joined);
        gw.Hold.SetResult();
        gw.Hold = null;
        await Task.WhenAll(writes[0], joined);
        await undo.RestoreAsync();                                      // after it landed: nothing more is sent
        Assert.False(press.Press());

        Assert.Equal(1, gw.UnarchiveWrites());
        Assert.Equal(1, undo.Writes);
        await store.RefreshAsync();
        Assert.Contains("otto/s-100", Keys(store.LiveSummaries()));
        Untouched(gw);
    }

    /// The hazard the press guards: the old route ran the unarchive on every Click, and two calls to the store's write
    /// send two PATCHes.
    [Fact]
    public async Task WithoutTheGuardTwoClicksWouldWriteTwice()
    {
        var (gw, store, trip) = await Make();
        await store.SetArchivedAsync(trip, true);
        var archived = trip with { Archived = true };
        await Task.WhenAll(store.SetArchivedAsync(archived, false), store.SetArchivedAsync(archived, false));
        Assert.Equal(2, gw.UnarchiveWrites());
    }

    /// A refused unarchive: the store keeps the chat archived and the error reaches the caller (the route's "Couldn’t
    /// Unarchive Chat" with the gateway's reason); Try Again writes once more and brings it back. Nothing else moves.
    [Fact]
    public async Task AFailedUndoSaysSoAndTryAgainBringsItBack()
    {
        var (gw, store, trip) = await Make();
        await store.SetArchivedAsync(trip, true);
        var undo = new ArchiveUndo(store, trip);
        gw.FailNext = 1;

        var failure = await Assert.ThrowsAsync<GatewayException>(undo.RestoreAsync);
        Assert.Equal("The stand-in refused this write.", SessionStore.ReasonOf(failure));
        Assert.Equal("Couldn’t Unarchive Chat", ArchiveUndo.FailureTitle);
        Assert.False(undo.Restored);
        Assert.DoesNotContain("otto/s-100", Keys(store.LiveSummaries()));
        Assert.Contains("otto/s-100", Keys(store.ArchivedSummaries()));
        await store.RefreshAsync();
        Assert.DoesNotContain("otto/s-100", Keys(store.LiveSummaries()));
        Assert.True(gw.Chats.Single(c => c.Profile == "otto" && c.Id == "s-100").Archived);

        await undo.RestoreAsync();                                      // Try Again
        Assert.True(undo.Restored);
        Assert.Equal(2, undo.Writes);
        Assert.Equal(2, gw.UnarchiveWrites());
        await store.RefreshAsync();
        Assert.Contains("otto/s-100", Keys(store.LiveSummaries()));
        Untouched(gw);
    }

    /// An unarchive the gateway took but whose answer was lost: Try Again replays the same request id (SessionWrite's
    /// fence), so the gateway applies the change once, and the chat is back.
    [Fact]
    public async Task ALostAnswerRetriesWithTheSameRequest()
    {
        var (gw, store, trip) = await Make();
        await store.SetArchivedAsync(trip, true);
        var undo = new ArchiveUndo(store, trip);
        gw.LoseNextAnswer = 1;

        var failure = await Assert.ThrowsAsync<GatewayException>(undo.RestoreAsync);
        Assert.Equal("Your gateway didn’t answer in time. Try again in a moment.", SessionStore.ReasonOf(failure));
        await undo.RestoreAsync();

        var unarchives = gw.Patches.Where(p => p.Body["archived"]!.GetValue<bool>() == false).ToList();
        Assert.Equal(2, unarchives.Count);
        Assert.Equal(unarchives[0].Body["request_id"]!.GetValue<string>(), unarchives[1].Body["request_id"]!.GetValue<string>());
        Assert.Equal(2, gw.Chats.Single(c => c.Profile == "otto" && c.Id == "s-100").Changes);   // archive, one unarchive
        await store.RefreshAsync();
        Assert.Contains("otto/s-100", Keys(store.LiveSummaries()));
        Untouched(gw);
    }

    /// The pill's time and holds are its life's (WIN-44); once its time runs out it goes, and a click that arrives after
    /// does nothing. Held, it stays and Undo still works.
    [Fact]
    public async Task APillWhoseTimeRanOutUndoesNothingAndAHeldOneStillUndoes()
    {
        var (gw, store, trip) = await Make();
        await store.SetArchivedAsync(trip, true);

        var now = DateTimeOffset.FromUnixTimeSeconds(1_000);
        Action? armed = null;
        UndoPillPress? press = null;
        var life = new UndoPillLife(new UndoPillClock(UndoPillClock.Seconds, false), () => now,
            (_, fire) => { armed = fire; return new Disarm(() => armed = null); }, () => press!.Gone());
        var undo = new ArchiveUndo(store, trip);
        press = new UndoPillPress(life.End, () => _ = undo.RestoreAsync());
        life.Start();
        now = now.AddSeconds(4);
        armed!();
        Assert.True(life.Ended);
        Assert.False(press.Open);
        Assert.False(press.Press());
        Assert.Equal(0, gw.UnarchiveWrites());

        var held = new UndoPillLife(new UndoPillClock(UndoPillClock.Seconds, false), () => now,
            (_, fire) => { armed = fire; return new Disarm(() => armed = null); }, () => { });
        var heldUndo = new ArchiveUndo(store, trip);
        Task? write = null;
        var heldPress = new UndoPillPress(held.End, () => write = heldUndo.RestoreAsync());
        held.Start();
        held.SetHold(UndoPillHold.Pointer, true);
        Assert.Null(armed);                                              // held: no timer runs
        Assert.True(heldPress.Press());
        Assert.True(held.Ended);
        await write!;
        Assert.Equal(1, gw.UnarchiveWrites());
        Untouched(gw);
    }

    private sealed class Disarm(Action run) : IDisposable
    {
        public void Dispose() => run();
    }
}
