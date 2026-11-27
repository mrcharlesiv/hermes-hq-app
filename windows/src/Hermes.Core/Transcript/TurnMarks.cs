namespace Hermes.Core.Transcripts;

// Port of HermesKit/Chat/Transcript/TurnMarks.swift: how long a turn took (docs/spec/3x-transcript.md §6.6), and the
// newest message a reader has seen in each chat (§4.1). Marks are remembered per chat scope, so another chat with the
// same message ids never gets them. The Mac keeps them in UserDefaults; here the app passes what it stored and a
// callback that saves the new list (or none, for a store that lives only in memory).

public static class TurnDuration
{
    private static int Rounded(double seconds) => (int)Math.Round(seconds, MidpointRounding.AwayFromZero);

    /// "4s", "1m 12s", "1h 3m"; null under one second (unknown is shown as nothing, never as a guess).
    public static string? Short(double seconds)
    {
        if (!double.IsFinite(seconds) || seconds < 1) return null;
        var total = Rounded(seconds);
        if (total < 60) return $"{total}s";
        if (total < 3600) return $"{total / 60}m {total % 60}s";
        return $"{total / 3600}h {total % 3600 / 60}m";
    }

    /// "Took 1 minute 12 seconds".
    public static string? Spoken(double seconds)
    {
        if (!double.IsFinite(seconds) || seconds < 1) return null;
        var total = Rounded(seconds);
        static string Unit(int n, string word) => $"{n} {word}{(n == 1 ? "" : "s")}";
        var parts = new List<string>();
        if (total >= 3600) parts.Add(Unit(total / 3600, "hour"));
        if (total >= 60 && total % 3600 / 60 > 0) parts.Add(Unit(total % 3600 / 60, "minute"));
        if (total < 3600 && total % 60 > 0) parts.Add(Unit(total % 60, "second"));
        return "Took " + string.Join(" ", parts);
    }
}

/// One stored duration mark: "<chat scope>\u0001<message id>" and its seconds.
public readonly record struct TurnMarkEntry(string Key, double Seconds);

/// Duration marks by chat scope and message id: 200 kept across all chats, oldest out first (Swift `TurnMarkStore`).
public sealed class TurnMarkStore
{
    public const int Limit = 200;
    /// The key the Mac stores the list under (UserDefaults), for a settings store that wants the same name.
    public const string StorageKey = "hqn.transcript.turnMarks.v1";

    private readonly object _lock = new();
    private readonly Action<IReadOnlyList<TurnMarkEntry>>? _save;
    private readonly List<string> _order = [];   // oldest first
    private readonly Dictionary<string, double> _seconds = [];

    /// `stored`: what `save` last wrote (oldest first), or null. `save`: called with the whole list after each change.
    public TurnMarkStore(IEnumerable<TurnMarkEntry>? stored = null, Action<IReadOnlyList<TurnMarkEntry>>? save = null)
    {
        _save = save;
        if (stored is null) return;
        foreach (var e in stored)
        {
            if (e.Key is null || _seconds.ContainsKey(e.Key)) continue;
            _order.Add(e.Key);
            _seconds[e.Key] = e.Seconds;
        }
    }

    private static string Key(string scope, string messageId) => scope + "\u0001" + messageId;

    public void Set(double value, string scope, string messageId)
    {
        if (!double.IsFinite(value) || value < 0 || scope.Length == 0 || messageId.Length == 0) return;
        List<TurnMarkEntry> snapshot;
        lock (_lock)
        {
            var k = Key(scope, messageId);
            if (_seconds.ContainsKey(k)) _order.Remove(k);
            _seconds[k] = value;
            _order.Add(k);
            while (_order.Count > Limit) { _seconds.Remove(_order[0]); _order.RemoveAt(0); }
            snapshot = [.. _order.Select(o => new TurnMarkEntry(o, _seconds.GetValueOrDefault(o)))];
        }
        _save?.Invoke(snapshot);
    }

    public double? Seconds(string scope, string messageId)
    {
        lock (_lock) return _seconds.TryGetValue(Key(scope, messageId), out var s) ? s : null;
    }

    /// A reply that was live ("local-…") got its stored id on a resync: the mark follows it.
    public void Move(string scope, string from, string to)
    {
        if (from == to || Seconds(scope, from) is not { } value) return;
        Set(value, scope, to);
    }

    public int Count { get { lock (_lock) return _order.Count; } }
}

/// What the reader last saw of a chat: the newest message's id, how many messages the chat had (to find the first
/// unseen one when ids changed on a resync), and when.
public sealed record SeenMark(string NewestId, int Count, DateTimeOffset At);

/// One stored seen mark, by chat.
public readonly record struct SeenEntry(string Chat, SeenMark Mark);

/// Where a reopened chat lands (Swift `SeenStore.Landing`).
public readonly record struct SeenLanding(bool Unseen, int FirstIndex)
{
    /// Nothing new (or nothing known): open as today (the newest end, or the restored place).
    public static readonly SeenLanding Usual = new(false, 0);
    /// Replies the reader has not seen: the first of them is the message at this index.
    public static SeenLanding UnseenAt(int index) => new(true, index);
}

/// What the reader last saw of each chat (120 chats kept), oldest out first (Swift `SeenStore`).
public sealed class SeenStore
{
    public const int Limit = 120;
    public const string StorageKey = "hqn.transcript.seen.v1";

    private readonly object _lock = new();
    private readonly Action<IReadOnlyList<SeenEntry>>? _save;
    private readonly List<string> _order = [];
    private readonly Dictionary<string, SeenMark> _marks = [];

    public SeenStore(IEnumerable<SeenEntry>? stored = null, Action<IReadOnlyList<SeenEntry>>? save = null)
    {
        _save = save;
        if (stored is null) return;
        foreach (var e in stored)
        {
            if (e.Chat is null || e.Mark is null || _marks.ContainsKey(e.Chat)) continue;
            _order.Add(e.Chat);
            _marks[e.Chat] = e.Mark;
        }
    }

    public void Mark(string chat, string newestId, int count, DateTimeOffset? now = null)
    {
        if (chat.Length == 0 || newestId.Length == 0) return;
        List<SeenEntry> snapshot;
        lock (_lock)
        {
            if (_marks.ContainsKey(chat)) _order.Remove(chat);
            _marks[chat] = new SeenMark(newestId, count, now ?? DateTimeOffset.Now);
            _order.Add(chat);
            while (_order.Count > Limit) { _marks.Remove(_order[0]); _order.RemoveAt(0); }
            snapshot = [.. _order.Where(_marks.ContainsKey).Select(k => new SeenEntry(k, _marks[k]))];
        }
        _save?.Invoke(snapshot);
    }

    public SeenMark? MarkFor(string chat)
    {
        lock (_lock) return _marks.GetValueOrDefault(chat);
    }

    public int Count { get { lock (_lock) return _order.Count; } }

    /// Where a reopened chat lands. `ids`: the chat's message ids, oldest first; `incoming`: true where the message is
    /// the bot's (an unseen run starts at a reply, not at your own message).
    public static SeenLanding Landing(SeenMark? mark, IReadOnlyList<string> ids, IReadOnlyList<bool> incoming)
    {
        if (mark is null || ids.Count == 0 || ids[^1] == mark.NewestId) return SeenLanding.Usual;
        int start;
        var seen = -1;
        for (var i = ids.Count - 1; i >= 0; i--) if (ids[i] == mark.NewestId) { seen = i; break; }
        if (seen >= 0) start = seen + 1;
        else if (mark.Count > 0 && mark.Count < ids.Count) start = mark.Count;
        else return SeenLanding.Usual;
        if (start >= ids.Count) return SeenLanding.Usual;
        for (var i = start; i < ids.Count; i++)
            if (i < incoming.Count && incoming[i]) return SeenLanding.UnseenAt(i);
        return SeenLanding.Usual;
    }
}
