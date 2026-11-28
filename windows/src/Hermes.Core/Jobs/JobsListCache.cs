using System.Runtime.CompilerServices;
using System.Text.Json.Nodes;
using Hermes.Core.Net;

namespace Hermes.Core.Jobs;

/// One shared cache for the cron REST reads two features both make (the Jobs store and the Tiles page each fired
/// `GET /api/cron/jobs` on their own tick). Kept per `GatewaySession` (never across gateway accounts): a key's first
/// caller fetches, callers arriving while that read is out share it, and callers within `ListFresh` of a landed read
/// reuse it. A write forgets its key so the refresh right after is a real read.
public sealed class JobsListCache
{
    /// How long a landed `GET /api/cron/jobs` answer is reused. Short: writes must not show stale lists for long.
    public static readonly TimeSpan ListFresh = TimeSpan.FromSeconds(15);

    private sealed class Slot
    {
        public JsonNode? Body;
        public DateTimeOffset At;
        public Task<JsonNode?>? InFlight;
    }

    private static readonly ConditionalWeakTable<GatewaySession, JobsListCache> PerSession = [];
    private readonly object _gate = new();
    private readonly Dictionary<string, Slot> _slots = [];

    public static JobsListCache For(GatewaySession session) => PerSession.GetValue(session, _ => new JobsListCache());

    /// `key`'s answer: read at most `ListFresh` ago, shared with the callers of the same moment, else `fetch`ed.
    public async Task<JsonNode?> ReadAsync(string key, Func<Task<JsonNode?>> fetch, CancellationToken ct = default)
    {
        Slot slot;
        Task<JsonNode?> mine;
        lock (_gate)
        {
            if (!_slots.TryGetValue(key, out var slotOrNull)) { slotOrNull = new Slot(); _slots[key] = slotOrNull; }
            slot = slotOrNull;
            if (slot.InFlight is { IsCompleted: false } inFlight)
            {
                mine = inFlight;
            }
            else
            {
                if (slot.Body != null && DateTimeOffset.UtcNow - slot.At < ListFresh) return slot.Body;
                var done = new TaskCompletionSource<JsonNode?>(TaskCreationOptions.RunContinuationsAsynchronously);
                slot.InFlight = done.Task;
                mine = FetchAsync(slot, done, fetch);
            }
        }
        return await mine.WaitAsync(ct).ConfigureAwait(false);
    }

    private async Task<JsonNode?> FetchAsync(Slot slot, TaskCompletionSource<JsonNode?> done, Func<Task<JsonNode?>> fetch)
    {
        try
        {
            var body = await fetch().ConfigureAwait(false);
            lock (_gate) { slot.Body = body; slot.At = DateTimeOffset.UtcNow; }
            done.SetResult(body);
            return body;
        }
        catch (Exception e)
        {
            // A failed read isn't kept: the next caller reads again.
            done.SetException(e);
            throw;
        }
        finally
        {
            lock (_gate) slot.InFlight = null;
        }
    }

    /// The answer for `key` goes: the next read is a real one (called before a write's follow-up refresh).
    public void Forget(string key)
    {
        lock (_gate) _slots.Remove(key);
    }
}
