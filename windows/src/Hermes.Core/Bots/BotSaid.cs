using System.Text.Json.Nodes;
using Hermes.Core.Chat;
using Hermes.Core.Groups;
using Hermes.Core.Model;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Bots;

// [botsaid] A Bots row's preview is the newest thing the bot itself said to you in its Bot Chat
// (port of HermesKit/Store/BotStore+BotSaid.swift and App/Chat/BotSaidShown.swift): never your own message,
// a scheduled run's report, another bot's delivery, a [SILENT] reply, or a reply folded into a bot-to-bot exchange.

public sealed record BotSaidEntry
{
    public required string Session { get; init; }
    public double At { get; init; }
    public string? Text { get; init; }
    public string? Mark { get; init; }
    public double? Newest { get; init; }
    public int? Rule { get; init; }
}

public static class BotSaidRules
{
    public const int Parallel = 3;
    public const int Tail = 30;
    public const int DeepTail = 160;
    public const int Rule = 2;
    public const string NothingShown = "[SILENT]";
    public static readonly TimeSpan FlushDelay = TimeSpan.FromMilliseconds(120);

    public sealed record ShownResult(string? Text, bool Settled);

    /// Everything the roster says of a chat that moves when a message is stored.
    public static string Mark(RosterSessionRef chat) =>
        $"{chat.LastActive ?? 0}|{chat.MessageCount ?? -1}|{chat.LiveMessageCount ?? -1}|{chat.Preview ?? ""}";

    /// An assistant message's text is something the bot said to you (not cron, delivery, process, or silent).
    public static bool IsOwnWords(string? text)
    {
        var trimmed = (text ?? "").Trim();
        if (trimmed.Length == 0 || RosterPreview.IsSilentOnly(trimmed)) return false;
        if (CronDeliveries.MayBeCron(trimmed) || CronDeliveries.ProcessNote(trimmed) != null) return false;
        if (RosterPreview.IsDelivery(trimmed) || TimelineNotes.IsScheduledWake(trimmed) || UpdateGroups.IsVoiceTranscript(trimmed)) return false;
        if (trimmed.StartsWith("[System:", StringComparison.Ordinal) || trimmed.StartsWith("[System note:", StringComparison.OrdinalIgnoreCase)) return false;
        return RosterPreview.CleanPreviewText(trimmed).Length > 0;
    }

    public static string? Latest(IEnumerable<JsonNode?> rows, DeliveryMessages.Seat? own = null, IReadOnlyList<DeliveryMessages.Seat>? seats = null) =>
        Shown(rows, own, seats).Text;

    /// The bot's newest words to you among `raw` (oldest first), using `UpdateGroups` folding rules.
    public static ShownResult Shown(IReadOnlyList<ChatMessage> raw, DeliveryMessages.Seat? own = null, IReadOnlyList<DeliveryMessages.Seat>? seats = null)
    {
        var (messages, rows) = ChatRows(raw, own, seats);
        for (var at = messages.Count - 1; at >= 0; at--)
        {
            if (messages[at].Role != Role.Assistant) continue;
            var ownRows = rows.At(at);
            for (var r = ownRows.Count - 1; r >= 0; r--)
            {
                var row = ownRows[r];
                if (!UpdateGroups.IsBotsReply(row) || !IsOwnWords(row.Text)) continue;
                if (rows.Interim(new UpdateGroups.Member(at, r))) continue;
                var line = string.Join(" ", row.Text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
                var clipped = line.Length > 200 ? line[..200] : line;
                var settled = false;
                for (var prev = 0; prev < at; prev++)
                    if (messages[prev].Role != Role.Assistant) { settled = true; break; }
                return new ShownResult(clipped, settled);
            }
        }
        return new ShownResult(null, false);
    }

    /// The same for a tail of stored rows, in any order.
    public static ShownResult Shown(IEnumerable<JsonNode?> rows, DeliveryMessages.Seat? own = null, IReadOnlyList<DeliveryMessages.Seat>? seats = null)
    {
        var ordered = OrderByRowId(rows);
        return Shown(HistoryFold.Fold(ordered), own, seats);
    }

    /// True when a stored tail holds something for you newer than `since` (gateway seconds).
    /// Another bot's message, this bot's messages to it, replies folded into bot talk, and background completions
    /// inside a bot-to-bot turn (#612) do NOT count as news for you.
    public static bool NewsForYou(
        IEnumerable<JsonNode?> rows,
        double since,
        DeliveryMessages.Seat? own = null,
        IReadOnlyList<DeliveryMessages.Seat>? seats = null,
        bool whole = false)
    {
        var ordered = OrderByRowId(rows);
        var timed = new List<(long? Id, double At)>();
        foreach (var row in ordered)
        {
            if (row.Num("timestamp") is { } at && double.IsFinite(at) && at > 0)
                timed.Add((RowIdOf(row), at));
        }
        if (timed.Count == 0) return ordered.Count > 0;
        if (!timed.Any(t => t.At > since)) return false;
        if (!whole && !timed.Any(t => t.At <= since)) return true;

        var folded = HistoryFold.Fold(ordered);
        var fresh = new HashSet<string>(StringComparer.Ordinal);
        foreach (var m in folded)
        {
            var stamp = (m.LatestTimestamp ?? m.Timestamp) is { } ts ? ts.ToUnixTimeMilliseconds() / 1000.0 : 0;
            if (stamp > since) { fresh.Add(m.Id); continue; }
            if (m.RowId is { } rid && timed.Any(t => t.Id == rid && t.At > since)) fresh.Add(m.Id);
        }

        var (messages, drawn) = ChatRows(folded, own, seats);
        var carried = false;
        for (var at = 0; at < messages.Count; at++)
        {
            var message = messages[at];
            if (message.RowId != null || message.Timestamp != null || message.LatestTimestamp != null)
                carried = fresh.Contains(message.Id);
            if (!carried) continue;
            var ownRows = drawn.At(at);
            for (var r = 0; r < ownRows.Count; r++)
            {
                if (IsForYou(ownRows[r], new UpdateGroups.Member(at, r), drawn)) return true;
            }
        }
        return false;
    }

    private static bool IsForYou(UpdateRow row, UpdateGroups.Member member, UpdateGroups.Rows rows) => row.Kind switch
    {
        UpdateRowKind.Bubble => UpdateGroups.IsBotsReply(row)
            ? !rows.Interim(member) && !string.IsNullOrWhiteSpace(row.Text)
            : true,
        UpdateRowKind.BackgroundResult => UpdateGroups.IsBotTalk(row)
            ? false
            : (!row.Cron && !row.Voice && IsInBotTalkTurn(member, rows) ? false : true),
        UpdateRowKind.Error or UpdateRowKind.Prompt => true,
        _ => false,
    };

    /// True when `member` sits inside a bot-to-bot turn (preceded by a bot-talk row with no user message or cron report
    /// in between), so background tool completions from that bot-to-bot turn do not light an unread dot (#612).
    public static bool IsInBotTalkTurn(UpdateGroups.Member member, UpdateGroups.Rows rows)
    {
        var minBack = Math.Max(0, member.Message - 8);
        for (var i = member.Message; i >= minBack; i--)
        {
            var own = rows.At(i);
            var upper = i == member.Message ? member.Row : own.Count;
            for (var r = upper - 1; r >= 0; r--)
            {
                var row = own[r];
                if (UpdateGroups.IsBotTalk(row)) return true;
                if (UpdateGroups.EndsTalk(row)) return false;
                if (UpdateGroups.IsBotsReply(row) && !rows.Interim(new UpdateGroups.Member(i, r))) return false;
            }
        }
        return false;
    }

    internal static List<JsonNode?> OrderByRowId(IEnumerable<JsonNode?> rows) =>
        [.. rows.Select((row, idx) => (row, idx, id: RowIdOf(row)))
            .OrderBy(x => x.id ?? long.MaxValue)
            .ThenBy(x => x.idx)
            .Select(x => x.row)];

    internal static long? RowIdOf(JsonNode? row) => row.Int("row_id") ?? row.Int("id");

    internal static double? NewestTimestamp(IEnumerable<JsonNode?> rows)
    {
        double? best = null;
        foreach (var row in rows)
        {
            if (row.Num("timestamp") is { } at && double.IsFinite(at) && at > 0 && (best is not { } b || at > b))
                best = at;
        }
        return best;
    }

    private static (IReadOnlyList<ChatMessage> Messages, UpdateGroups.Rows Rows) ChatRows(
        IReadOnlyList<ChatMessage> raw, DeliveryMessages.Seat? own, IReadOnlyList<DeliveryMessages.Seat>? seats)
    {
        var roster = seats ?? [];
        var effectiveOwn = own ?? new DeliveryMessages.Seat("", "", null);
        var messages = DeliveryMessages.Resolve(raw, roster).Messages;
        messages = BotDMs.Resolve(messages, roster).Messages;
        var input = new UpdateGroups.Input
        {
            Messages = messages,
            BotName = string.IsNullOrWhiteSpace(effectiveOwn.Name) ? "Hermes" : effectiveOwn.Name,
            Bots = roster,
            OwnFace = string.IsNullOrEmpty(effectiveOwn.Profile)
                ? null
                : new ChatSender(effectiveOwn.Profile, effectiveOwn.Name, effectiveOwn.Head, effectiveOwn.Profile, null),
        };
        return (messages, new UpdateGroups.Rows(input));
    }
}

public sealed partial class BotStore
{
    private readonly Dictionary<string, string> _botSaidMarks = [];
    private readonly HashSet<string> _botSaidStale = [];
    private readonly Dictionary<string, (string Mark, DateTimeOffset Asked)> _botSaidOut = [];
    private readonly Dictionary<string, DateTimeOffset> _botSaidSeenAt = [];
    private readonly Dictionary<string, DateTimeOffset> _unreadHeldAt = [];
    private readonly List<(string Profile, string Session, double At, string Mark)> _botSaidQueue = [];
    private readonly SemaphoreSlim _botSaidParallel = new(BotSaidRules.Parallel, BotSaidRules.Parallel);
    private int _botSaidDirty;
    private CancellationTokenSource? _botSaidFlushCts;
    private bool _botSaidStopped;

    public void StopBotSaid()
    {
        CancellationTokenSource? cts;
        lock (_gate)
        {
            _botSaidStopped = true;
            cts = _botSaidFlushCts;
            _botSaidFlushCts = null;
        }
        cts?.Cancel();
        cts?.Dispose();
    }

    /// Replaces each Bot Chat's preview with the bot's own newest words when read.
    public List<RosterProfile> WithBotSaid(IEnumerable<RosterProfile> rows)
    {
        Dictionary<string, BotSaidEntry> said;
        lock (_gate)
        {
            if (Device.BotSaid.Count == 0) return [.. rows];
            said = new Dictionary<string, BotSaidEntry>(Device.BotSaid);
        }
        var out_ = new List<RosterProfile>();
        foreach (var row in rows)
        {
            if (!said.TryGetValue(row.Name, out var entry) || row.CanonicalSession is not { } canonical
                || (canonical.OpenId != entry.Session && !canonical.Ids.Contains(entry.Session)))
            {
                out_.Add(row);
                continue;
            }
            var copy = (JsonObject)row.Raw.DeepClone();
            if (copy["canonical_session"] is JsonObject cs)
            {
                cs["preview"] = entry.Text ?? BotSaidRules.NothingShown;
                if (entry.Newest is { } newest && newest > (canonical.LastActive ?? 0))
                    cs["last_active"] = newest;
            }
            out_.Add(RosterProfile.From(copy) ?? row);
        }
        return out_;
    }

    /// Advances each Bot Chat's activity time to its newest stored row when measured.
    public List<RosterProfile> WithChatActivity(IEnumerable<RosterProfile> rows)
    {
        Dictionary<string, BotSaidEntry> said;
        lock (_gate)
        {
            if (Device.BotSaid.Count == 0) return [.. rows];
            said = new Dictionary<string, BotSaidEntry>(Device.BotSaid);
        }
        var out_ = new List<RosterProfile>();
        foreach (var row in rows)
        {
            if (!said.TryGetValue(row.Name, out var entry) || entry.Newest is not { } newest
                || row.CanonicalSession is not { } canonical
                || (canonical.OpenId != entry.Session && !canonical.Ids.Contains(entry.Session))
                || newest <= (canonical.LastActive ?? 0))
            {
                out_.Add(row);
                continue;
            }
            var copy = (JsonObject)row.Raw.DeepClone();
            if (copy["canonical_session"] is JsonObject cs) cs["last_active"] = newest;
            out_.Add(RosterProfile.From(copy) ?? row);
        }
        return out_;
    }

    /// Records the roster's raw marks before `WithChatActivity`.
    public void NoteRosterMarks(IEnumerable<RosterProfile> rows)
    {
        lock (_gate)
        {
            _botSaidMarks.Clear();
            foreach (var row in rows)
                if (row.CanonicalSession is { } c) _botSaidMarks.TryAdd(row.Name, BotSaidRules.Mark(c));
        }
    }

    /// Marks a bot's preview stale and kicks off a tail read.
    public void RereadBotSaid(string profile)
    {
        lock (_gate) _botSaidStale.Add(profile);
        _ = RefreshBotSaidAsync();
    }

    /// Records words the bot itself just said to you, seen on this device. Returns true when kept words changed.
    public bool NoteBotSaid(string profile, string sessionId, string text, double at, bool serverTime = false)
    {
        if (!BotSaidRules.IsOwnWords(text)) return false;
        var line = string.Join(" ", text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        var clipped = line.Length > 200 ? line[..200] : line;
        lock (_gate)
        {
            double? newest = Device.BotSaid.TryGetValue(profile, out var old) && old.Session == sessionId ? old.Newest : null;
            if (serverTime && at > (newest ?? 0)) newest = at;
            var entry = new BotSaidEntry
            {
                Session = sessionId,
                At = at,
                Text = clipped,
                Newest = newest,
                Rule = BotSaidRules.Rule,
            };
            _botSaidSeenAt[profile] = DateTimeOffset.UtcNow;
            if (Device.BotSaid.TryGetValue(profile, out var existing) && existing == entry) return false;
            Device.BotSaid[profile] = entry;
        }
        Persist();
        return true;
    }

    /// Queues and runs tail reads (up to 3 in parallel, 120ms coalesced flush) for moved Bot Chats.
    public Task RefreshBotSaidAsync(CancellationToken ct = default)
    {
        if (_botSaidStopped || !ReadsBotSaid) return Task.CompletedTask;
        var profiles = Profiles();
        var tasks = new List<Task>();
        lock (_gate)
        {
            var known = profiles.Select(p => p.Name).ToHashSet();
            foreach (var staleKey in Device.BotSaid.Keys.Where(k => !known.Contains(k)).ToList())
                Device.BotSaid.Remove(staleKey);

            foreach (var profile in profiles)
            {
                if (profile.CanonicalSession is not { } canonical || canonical.Id.Length == 0 || !RosterRules.HoldsMessages(canonical))
                    continue;
                var at = canonical.LastActive ?? 0;
                var mark = _botSaidMarks.GetValueOrDefault(profile.Name) ?? BotSaidRules.Mark(canonical);
                var owed = Device.Unread.HeldSince(profile.Name) != null
                    && !_botSaidOut.ContainsKey(profile.Name)
                    && !_botSaidQueue.Any(q => q.Profile == profile.Name);
                var stale = _botSaidStale.Contains(profile.Name) || owed;
                if (!stale && Device.BotSaid.TryGetValue(profile.Name, out var entry)
                    && entry.Session == canonical.OpenId && entry.Mark == mark && entry.Rule == BotSaidRules.Rule)
                    continue;
                if (_botSaidQueue.Any(q => q.Profile == profile.Name && q.Mark == mark)) continue;
                if (!stale && _botSaidOut.TryGetValue(profile.Name, out var inflight) && inflight.Mark == mark) continue;
                _botSaidStale.Remove(profile.Name);
                _botSaidQueue.RemoveAll(q => q.Profile == profile.Name);
                _botSaidQueue.Add((profile.Name, canonical.OpenId, at, mark));
            }
            while (_botSaidOut.Count < BotSaidRules.Parallel)
            {
                var idx = _botSaidQueue.FindIndex(q => !_botSaidOut.ContainsKey(q.Profile));
                if (idx < 0) break;
                var item = _botSaidQueue[idx];
                _botSaidQueue.RemoveAt(idx);
                _botSaidOut[item.Profile] = (item.Mark, DateTimeOffset.UtcNow);
                tasks.Add(RunOneBotSaidAsync(item, ct));
            }
        }
        return tasks.Count == 0 ? Task.CompletedTask : Task.WhenAll(tasks);
    }

    private async Task RunOneBotSaidAsync((string Profile, string Session, double At, string Mark) item, CancellationToken ct)
    {
        await _botSaidParallel.WaitAsync(ct);
        try
        {
            var seats = DeliveryRoster.Seats;
            var own = seats.FirstOrDefault(s => s.Profile == item.Profile)
                ?? new DeliveryMessages.Seat(item.Profile, item.Profile, null);
            double? since;
            lock (_gate)
                since = Device.Unread.HeldSince(item.Profile)
                    ?? (Device.Unread.Baselines.TryGetValue(item.Profile, out var b) ? (double?)b : null);

            async Task<List<JsonNode?>?> FetchTailAsync(int limit)
            {
                try
                {
                    var path = $"/api/sessions/{Uri.EscapeDataString(item.Session)}/messages";
                    var query = new List<KeyValuePair<string, string>>
                    {
                        new("profile", item.Profile),
                        new("limit", limit.ToString()),
                        new("order", "latest"),
                        new("inline_images", "false"),
                    };
                    var ans = await _gw.RestAsync(HttpMethod.Get, path, query, ct: ct);
                    if (!ans.Ok || ans.Json is not JsonObject root) return null;
                    return (root["messages"] as JsonArray ?? []).Cast<JsonNode?>().ToList();
                }
                catch (Exception) { return null; }
            }

            var rows = await FetchTailAsync(BotSaidRules.Tail);
            var shown = rows != null ? BotSaidRules.Shown(rows, own, seats) : null;
            if (rows != null && shown != null && !shown.Settled && rows.Count >= BotSaidRules.Tail)
            {
                var deep = await FetchTailAsync(BotSaidRules.DeepTail);
                if (deep != null && deep.Count > rows.Count)
                {
                    rows = deep;
                    shown = BotSaidRules.Shown(deep, own, seats);
                }
            }

            var asked = rows != null && rows.Count > BotSaidRules.Tail ? BotSaidRules.DeepTail : BotSaidRules.Tail;
            if (since is { } s1 && rows != null && asked == BotSaidRules.Tail && rows.Count >= asked
                && !rows.Any(r => (r.Num("timestamp") ?? double.PositiveInfinity) <= s1))
            {
                var deep = await FetchTailAsync(BotSaidRules.DeepTail);
                if (deep != null && deep.Count > rows.Count)
                {
                    rows = deep;
                    shown = BotSaidRules.Shown(deep, own, seats);
                    asked = BotSaidRules.DeepTail;
                }
            }

            var whole = rows != null && rows.Count < asked;
            bool? forYou = since is { } s2 && rows != null
                ? BotSaidRules.NewsForYou(rows, s2, own, seats, whole)
                : null;
            if (since is { } s3 && forYou == false && rows != null && asked == BotSaidRules.Tail && rows.Count >= asked)
            {
                var deep = await FetchTailAsync(BotSaidRules.DeepTail);
                if (deep != null && deep.Count > rows.Count)
                {
                    rows = deep;
                    shown = BotSaidRules.Shown(deep, own, seats);
                    whole = deep.Count < BotSaidRules.DeepTail;
                    forYou = BotSaidRules.NewsForYou(deep, s3, own, seats, whole);
                }
            }

            ApplyBotSaidRead(item, rows, shown?.Text, since, forYou, whole, own, seats);
        }
        finally
        {
            _botSaidParallel.Release();
        }
    }

    private void ApplyBotSaidRead(
        (string Profile, string Session, double At, string Mark) item,
        List<JsonNode?>? rows,
        string? text,
        double? since,
        bool? forYou,
        bool whole,
        DeliveryMessages.Seat own,
        IReadOnlyList<DeliveryMessages.Seat> seats)
    {
        DateTimeOffset? asked = null;
        bool flushNow = false;
        bool scheduleFlush = false;
        bool pumpAgain = false;

        lock (_gate)
        {
            if (_botSaidOut.Remove(item.Profile, out var info)) asked = info.Asked;
            if (_botSaidStopped) return;
            if (rows == null)
            {
                SettleUnreadLocked(item.Profile, null, since, forYou, whole, own, seats, asked, born: false);
                flushNow = _botSaidDirty > 0 && _botSaidQueue.Count == 0 && _botSaidOut.Count == 0;
                scheduleFlush = _botSaidDirty > 0 && !flushNow;
            }
            else if (Device.BotSaid.TryGetValue(item.Profile, out var seen)
                && seen.Mark == null && seen.Session == item.Session
                && asked is { } a && _botSaidSeenAt.TryGetValue(item.Profile, out var seenAt) && seenAt > a)
            {
                // Live reply seen locally after this tail read started wins.
            }
            else
            {
                var old = Device.BotSaid.TryGetValue(item.Profile, out var prev) && prev.Session == item.Session ? prev : null;
                var keptText = text ?? (old?.Rule == BotSaidRules.Rule ? old.Text : null);
                var measured = BotSaidRules.NewestTimestamp(rows);
                var newest = measured is { } m && old?.Newest is { } on ? Math.Max(m, on) : measured ?? old?.Newest;
                var waited = Device.Unread.HeldSince(item.Profile) != null;

                if (newest is { } newestVal)
                {
                    var rowIdx = _rows.FindIndex(r => RosterText.Trimmed(r["name"]) == item.Profile);
                    if (rowIdx >= 0 && RosterProfile.From(_rows[rowIdx]) is { } prof && prof.CanonicalSession is { } cs
                        && (cs.OpenId == item.Session || cs.Ids.Contains(item.Session))
                        && newestVal > (cs.LastActive ?? 0))
                    {
                        var copy = (JsonObject)_rows[rowIdx].DeepClone();
                        if (copy["canonical_session"] is JsonObject cso) cso["last_active"] = newestVal;
                        _rows[rowIdx] = copy;
                        var updatedProf = RosterProfile.From(copy)!;
                        if (old?.Newest == null)
                            Device.Unread.Baselines[item.Profile] = Math.Max(Device.Unread.Baselines.GetValueOrDefault(item.Profile), newestVal);
                        else
                            Device.Unread.Reconcile([updatedProf], p => p.Name == VisibleBot, holdForCheck: ReadsBotSaid);
                    }
                }

                SettleUnreadLocked(item.Profile, rows, since, forYou, whole, own, seats, asked, born: !waited);

                var entry = new BotSaidEntry
                {
                    Session = item.Session,
                    At = item.At,
                    Text = keptText,
                    Mark = item.Mark,
                    Newest = newest,
                    Rule = BotSaidRules.Rule,
                };
                if (!Device.BotSaid.TryGetValue(item.Profile, out var cur) || cur != entry)
                {
                    Device.BotSaid[item.Profile] = entry;
                    _botSaidDirty++;
                }

                if (_botSaidDirty > 0)
                {
                    flushNow = _botSaidDirty >= 6 || (_botSaidQueue.Count == 0 && _botSaidOut.Count == 0);
                    scheduleFlush = !flushNow;
                }
            }
            pumpAgain = _botSaidQueue.Count > 0 || Device.Unread.HeldSince(item.Profile) != null;
        }

        if (flushNow) FlushBotSaid(immediate: true);
        else if (scheduleFlush) FlushBotSaid(immediate: false);
        if (pumpAgain) _ = RefreshBotSaidAsync();
    }

    /// Settles a held unread dot for `profile` using `BotSaidRules.NewsForYou` (#612).
    public void SettleUnread(string profileName, IEnumerable<JsonNode?>? rows, bool whole = false)
    {
        var seats = DeliveryRoster.Seats;
        var own = seats.FirstOrDefault(s => s.Profile == profileName)
            ?? new DeliveryMessages.Seat(profileName, profileName, null);
        var changed = false;
        lock (_gate)
        {
            changed = SettleUnreadLocked(profileName, rows?.ToList(), null, null, whole, own, seats, asked: null, born: true);
        }
        if (changed) { Persist(); Rebuild(); }
    }

    private bool SettleUnreadLocked(
        string name,
        List<JsonNode?>? rows,
        double? checkedSince,
        bool? checkedForYou,
        bool whole,
        DeliveryMessages.Seat own,
        IReadOnlyList<DeliveryMessages.Seat> seats,
        DateTimeOffset? asked,
        bool born)
    {
        if (Device.Unread.HeldSince(name) is not { } since) return false;
        var profile = Profiles().FirstOrDefault(p => p.Name == name);
        if (profile == null) return false;
        if (!born && asked is { } a && _unreadHeldAt.TryGetValue(name, out var heldAt) && a < heldAt) return false;

        bool forYou;
        if (rows == null) forYou = true;
        else if (checkedSince == since && checkedForYou is { } verdict) forYou = verdict;
        else forYou = BotSaidRules.NewsForYou(rows, since, own, seats, whole);

        _unreadHeldAt.Remove(name);
        Device.Unread.Settle(profile, forYou);
        _botSaidDirty++;
        return true;
    }

    private void FlushBotSaid(bool immediate)
    {
        if (immediate)
        {
            CancellationTokenSource? oldCts;
            lock (_gate)
            {
                oldCts = _botSaidFlushCts;
                _botSaidFlushCts = null;
                if (_botSaidDirty == 0 || _botSaidStopped) return;
                _botSaidDirty = 0;
            }
            oldCts?.Cancel();
            oldCts?.Dispose();
            Persist();
            Rebuild();
            return;
        }

        CancellationTokenSource cts;
        lock (_gate)
        {
            if (_botSaidFlushCts != null || _botSaidStopped) return;
            _botSaidFlushCts = cts = new CancellationTokenSource();
        }
        _ = Task.Run(async () =>
        {
            try
            {
                await Task.Delay(BotSaidRules.FlushDelay, cts.Token);
                FlushBotSaid(immediate: true);
            }
            catch (OperationCanceledException) { }
        });
    }
}
