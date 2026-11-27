namespace Hermes.Core.Net;

// [WIN-MEMO-SEND-WIRE] `GET /api/config` shared by the readers that only read it (HermesKit/Net/SharedConfigReads.swift
// at 93f984bb1, [load-cache]). A read joins one in flight for the same query, and an answer under `maxAge` old is
// reused. Any write through the session (a REST call that isn't a read) drops what is kept and lets the next reader
// start afresh, before the write is sent and again once it is answered. The memo pipeline's speech-to-text check reads
// through it with `maxAge` zero (only a read in flight is shared). Settings pages read past it: they edit what they read.

public sealed class SharedConfigReads
{
    /// How long an answer stands in for a new read when the reader doesn't say.
    public static readonly TimeSpan DefaultMaxAge = TimeSpan.FromSeconds(10);

    private sealed record Flight(ulong Id, Task<byte[]> Task);
    private sealed record Kept(byte[] Data, long At);

    private readonly object _gate = new();
    private readonly Dictionary<string, Flight> _flights = [];
    private readonly Dictionary<string, Kept> _kept = [];
    private readonly TimeProvider _time;
    private ulong _nextId;
    private int _started;

    public SharedConfigReads(TimeProvider? time = null) => _time = time ?? TimeProvider.System;

    /// The key for a query: its items in order ("" for none).
    public static string Key(IEnumerable<KeyValuePair<string, string>> query) =>
        string.Join("&", query.Select(q => $"{q.Key}={q.Value}"));

    /// Reads started (the tests count them).
    public int ReadsStarted { get { lock (_gate) return _started; } }

    /// The config for `query`: kept (under `maxAge` old), the read in flight, or a new read through `read`. `maxAge`
    /// zero: only a read in flight is shared. A failed read is never kept.
    public Task<byte[]> DataAsync(IReadOnlyList<KeyValuePair<string, string>> query, TimeSpan? maxAge, Func<Task<byte[]>> read)
    {
        var age = maxAge ?? DefaultMaxAge;
        var key = Key(query);
        var now = _time.GetTimestamp();
        lock (_gate)
        {
            if (age > TimeSpan.Zero && _kept.TryGetValue(key, out var kept) && _time.GetElapsedTime(kept.At, now) <= age)
                return Task.FromResult(kept.Data);
            if (_flights.TryGetValue(key, out var flight)) return flight.Task;
            var id = ++_nextId;
            _started++;
            // Made under the lock: its own bookkeeping (`Finish`) waits for the lock, so it always finds its flight.
            var task = Run(key, id, read);
            _flights[key] = new Flight(id, task);
            return task;
        }
    }

    private async Task<byte[]> Run(string key, ulong id, Func<Task<byte[]>> read)
    {
        await Task.Yield();
        try
        {
            var data = await read();
            Finish(key, id, data);
            return data;
        }
        catch
        {
            Finish(key, id, null);
            throw;
        }
    }

    private void Finish(string key, ulong id, byte[]? data)
    {
        lock (_gate)
        {
            // A read that `Invalidate` let go no longer speaks for the key: it neither clears nor fills it.
            if (!_flights.TryGetValue(key, out var flight) || flight.Id != id) return;
            _flights.Remove(key);
            if (data != null) _kept[key] = new Kept(data, _time.GetTimestamp());
        }
    }

    /// A write: nothing kept is reused, and reads in flight finish for their own callers only.
    public void Invalidate()
    {
        lock (_gate)
        {
            _kept.Clear();
            _flights.Clear();
        }
    }

    /// Whether this RPC may change the config (it drops what is kept).
    public static bool Writes(string rpcMethod) => rpcMethod.StartsWith("config.", StringComparison.Ordinal);
}
