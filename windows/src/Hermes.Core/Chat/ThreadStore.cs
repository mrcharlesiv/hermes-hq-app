using System.Runtime.CompilerServices;
using System.Text.Json.Nodes;
using Hermes.Core.Bots;
using Hermes.Core.Model;
using Hermes.Core.Sessions;
using Hermes.Core.Settings;

namespace Hermes.Core.Chat;

/// [threads] One account's session threads (port of App/Chat/Threads/ThreadStore.swift):
/// tracks threads started in this run (off-screen `ChatSession`s), listed gateway sessions matched via durable
/// `BotThreadLink`s (persisted in `IDeviceStore`), busy-chat auto-routing latches, availability probes,
/// `ThreadContextNote` reconciliation, and thread-session filtering.
public sealed class ThreadStore
{
    public const int IdleLive = 4;

    private sealed class Entry(string key, string profile, string parentScope, string? parentId, string? storedId, DateTimeOffset startedAt)
    {
        public readonly string Key = key;
        public readonly string Profile = profile;
        public readonly string ParentScope = parentScope;
        public string? ParentId = parentId;
        public string? StoredId = storedId;
        public ChatSession? Live;
        public DateTimeOffset StartedAt = startedAt;
        public string? AnchorMessageId;
        public int? AnchorRow;
        public string? RowTitle;
        public List<ChatMessage> Kept = [];
        public string? ReadStamp;
        public bool Reading;
        public string? Problem;
        public DateTimeOffset LastChange = DateTimeOffset.UtcNow;
        public int DrawnHash;
    }

    private sealed class BusyLatch
    {
        public required string Key { get; init; }
        public string? StoredId { get; set; }
        public int HeldAt { get; init; }
        public DateTimeOffset LastActivity { get; set; }
        public OwnerWait? Reason { get; set; }
        public bool MainIdleSinceHold { get; set; }
        public WeakReference<ChatSession>? Parent { get; init; }
    }

    private readonly IDeviceStore _disk;
    private readonly string _diskKey;
    private readonly object _gate = new();
    private readonly List<Entry> _entries = [];
    private readonly Dictionary<string, BusyLatch> _busyThreads = [];
    private readonly HashSet<string> _optedOutScopes = [];
    private readonly Dictionary<string, CancellationTokenSource> _availabilityProbes = [];
    private readonly Dictionary<string, List<string>> _pendingReconciliation = [];
    private readonly Dictionary<string, string> _restoredReconciliation = [];
    private List<BotThreadLink> _links;

    /// Optional client for creating new thread sessions and fetching thread histories lazily.
    public HermesClient? Client { get; set; }

    /// Optional custom factory used by tests or hosts to create a live thread `ChatSession`:
    /// `(profile, storedId, title, extraParams) -> ChatSession?`.
    public Func<string, string, string, JsonObject, ChatSession?>? ThreadSessionFactory { get; set; }

    /// Polling interval for the background main-chat availability probe (5 s in production; tests shorten it).
    public TimeSpan ProbeInterval { get; set; } = TimeSpan.FromSeconds(5);

    /// Raised when any thread of `profile` changes (messages, title, latch, banner).
    public event Action<string>? Changed;

    public ThreadStore(string accountId, IDeviceStore? disk = null)
    {
        _disk = disk ?? new MemoryDeviceStore();
        _diskKey = "threads-" + accountId;
        _links = LoadLinks();
    }

    public IReadOnlyList<BotThreadLink> Links { get { lock (_gate) return [.. _links]; } }

    private List<BotThreadLink> LoadLinks()
    {
        var raw = _disk.Read(_diskKey);
        if (string.IsNullOrEmpty(raw)) return [];
        return BotThreadLink.Decode(J.Parse(raw));
    }

    private void SaveLinksLocked()
    {
        var arr = new JsonArray();
        foreach (var link in _links) arr.Add(link.ToJson());
        _disk.Write(_diskKey, arr.ToJsonString());
    }

    /// Persists a durable `BotThreadLink` (newest first, deduped by `(Profile, StoredId)`, capped at `MaxKept`).
    public void RecordBotThread(BotThreadLink link)
    {
        lock (_gate)
        {
            _links.RemoveAll(x => x.Profile == link.Profile && x.StoredId == link.StoredId);
            _links.Insert(0, link);
            if (_links.Count > BotThreadLink.MaxKept)
                _links.RemoveRange(BotThreadLink.MaxKept, _links.Count - BotThreadLink.MaxKept);
            SaveLinksLocked();
        }
    }

    /// Merges synced thread links across devices.
    public void MergeSyncedLinks(IReadOnlyList<BotThreadLink> remote, IReadOnlyList<BotThreadLink> @base, BotThreadLink.MergePolicy policy)
    {
        lock (_gate)
        {
            _links = BotThreadLink.Merged(_links, remote, @base, policy);
            SaveLinksLocked();
        }
    }

    /// Stable scope key for a parent chat's busy latch, opt-out, availability probe, and reconciliation queue.
    public static string ScopeKey(ChatSession parent)
    {
        if (parent.IsBotChat) return $"bot:{parent.Profile}";
        if (!string.IsNullOrEmpty(parent.StoredId)) return $"session:{parent.StoredId}";
        return $"ephemeral:{RuntimeHelpers.GetHashCode(parent)}";
    }

    /// Known parent session ids for `parent` (bot chats also include the bot's canonical session id).
    public static HashSet<string> ParentIds(ChatSession parent, string? canonicalSessionId = null)
    {
        var ids = new HashSet<string>(StringComparer.Ordinal);
        if (!string.IsNullOrEmpty(parent.StoredId)) ids.Add(parent.StoredId);
        if (parent.IsBotChat && !string.IsNullOrEmpty(canonicalSessionId)) ids.Add(canonicalSessionId);
        return ids;
    }

    /// True when `storedId` is already a thread session (so opening it never nests threads and Sessions can filter it).
    public bool IsThreadSession(string storedId, string profile, string? canonicalSessionId = null, SidebarSessionRow? row = null)
    {
        lock (_gate)
        {
            if (_entries.Any(e => e.Profile == profile && (e.StoredId == storedId || e.Live?.StoredId == storedId)))
                return true;
            if (_links.Any(l => l.Profile == profile && l.StoredId == storedId))
                return true;
        }
        if (!string.IsNullOrEmpty(canonicalSessionId) && row?.ParentSessionId == canonicalSessionId)
            return true;
        return false;
    }

    /// Filters known thread sessions out of a Sessions sidebar list.
    public List<SidebarSessionRow> FilterOutThreads(
        IEnumerable<SidebarSessionRow> rows,
        IReadOnlyDictionary<string, string>? canonicalByProfile = null)
    {
        var out_ = new List<SidebarSessionRow>();
        foreach (var row in rows)
        {
            string? canonical = null;
            canonicalByProfile?.TryGetValue(row.Profile, out canonical);
            if (!IsThreadSession(row.Id, row.Profile, canonical, row)) out_.Add(row);
        }
        return out_;
    }

    /// The threads of the parent chat known by `parentIds`, oldest first.
    public List<ChatThread> Threads(
        string profile,
        IReadOnlySet<string> parentIds,
        bool isBotChat = true,
        IEnumerable<SidebarSessionRow>? listedRows = null,
        Func<string, bool>? isSessionWorking = null)
    {
        if (listedRows != null) AdoptListed(profile, parentIds, isBotChat, listedRows);
        lock (_gate)
        {
            return [.. _entries
                .Where(e => e.Profile == profile && Belongs(e, parentIds, isBotChat))
                .OrderBy(e => e.StartedAt)
                .Select(e => ToChatThread(e, isSessionWorking))];
        }
    }

    private static bool Belongs(Entry entry, IReadOnlySet<string> parentIds, bool isBotChat) =>
        entry.ParentId is { } parent ? parentIds.Contains(parent) : isBotChat;

    private static ChatThread ToChatThread(Entry entry, Func<string, bool>? isSessionWorking)
    {
        var live = entry.Live;
        var title = new[] { live?.Title, entry.RowTitle }
            .FirstOrDefault(t => !string.IsNullOrWhiteSpace(t) && t!.Trim() != ThreadRules.DefaultTitle && !ThreadRules.IsInheritedBotChatTitle(t));
        var messages = live?.Messages ?? entry.Kept;
        var running = live != null
            ? (live.Busy || (messages.Count == 0 && live.ThreadProblem == null))
            : (entry.StoredId != null && (isSessionWorking?.Invoke(entry.StoredId) ?? false));
        return new ChatThread(
            Id: entry.Key,
            StoredId: live?.StoredId ?? entry.StoredId,
            Title: title,
            StartedAt: entry.StartedAt,
            AnchorMessageId: entry.AnchorMessageId,
            AnchorRow: entry.AnchorRow,
            Messages: messages,
            Running: running,
            Problem: live?.ThreadProblem ?? entry.Problem);
    }

    /// Adopts listed gateway rows matching persisted `BotThreadLink`s (and legacy `parent_session_id` on bot chats).
    public void AdoptListed(string profile, IReadOnlySet<string> parentIds, bool isBotChat, IEnumerable<SidebarSessionRow> listedRows)
    {
        var byId = new Dictionary<string, SidebarSessionRow>(StringComparer.Ordinal);
        foreach (var r in listedRows) byId[r.Id] = r;

        var toRead = new List<(Entry Entry, string Stamp)>();
        lock (_gate)
        {
            void AdoptRow(SidebarSessionRow row, string parent, int? linkedAnchorRow = null, double? linkedStartedAt = null)
            {
                var entry = _entries.FirstOrDefault(e => e.Profile == profile && (e.StoredId == row.Id || e.Live?.StoredId == row.Id));
                if (entry == null)
                {
                    var at = linkedStartedAt ?? row.StartedAt ?? row.LastActive ?? DateTimeOffset.UtcNow.ToUnixTimeSeconds();
                    var scope = isBotChat ? $"bot:{profile}" : $"session:{parent}";
                    entry = new Entry(row.Id, profile, scope, parent, row.Id, DateTimeOffset.FromUnixTimeSeconds((long)at));
                    _entries.Add(entry);
                }
                else if (entry.StoredId == null)
                {
                    entry.StoredId = row.Id;
                }
                if (entry.AnchorRow == null && linkedAnchorRow != null) entry.AnchorRow = linkedAnchorRow;
                entry.RowTitle = row.Title;
                if (entry.Live != null) return;
                var stamp = $"{row.LastActive ?? 0}|{row.MessageCount ?? 0}";
                if (entry.ReadStamp != stamp && !entry.Reading)
                {
                    entry.Reading = true;
                    toRead.Add((entry, stamp));
                }
            }

            foreach (var link in _links.Where(l => l.Profile == profile && parentIds.Contains(l.ParentId)))
            {
                if (byId.TryGetValue(link.StoredId, out var row) && row.Archived != true)
                    AdoptRow(row, link.ParentId, link.AnchorRow, link.StartedAt);
            }
            if (isBotChat)
            {
                foreach (var row in byId.Values.Where(r => r.Profile == profile && r.Archived != true))
                    if (row.ParentSessionId is { } parent && parentIds.Contains(parent))
                        AdoptRow(row, parent);
            }
        }

        foreach (var (entry, stamp) in toRead)
            _ = ReadEntryAsync(entry, stamp);
    }

    private async Task ReadEntryAsync(Entry entry, string stamp)
    {
        var client = Client;
        var stored = entry.StoredId;
        if (client == null || string.IsNullOrEmpty(stored))
        {
            lock (_gate) entry.Reading = false;
            return;
        }
        try
        {
            var q = new List<KeyValuePair<string, string>>
            {
                new("profile", entry.Profile),
                new("limit", "200"),
                new("order", "latest"),
                new("include_compacted", "true"),
            };
            var json = await client.Session.GetJsonAsync($"/api/sessions/{Uri.EscapeDataString(stored)}/messages", q);
            var result = ThreadFetch.Read(json.Arr("messages") ?? []);
            lock (_gate)
            {
                entry.Reading = false;
                entry.ReadStamp = stamp;
                if (entry.Live != null) return;
                entry.Kept = [.. result.Messages];
                if (result.AnchorRow != null) entry.AnchorRow = result.AnchorRow;
                entry.LastChange = DateTimeOffset.UtcNow;
            }
            Changed?.Invoke(entry.Profile);
        }
        catch (Exception)
        {
            lock (_gate) entry.Reading = false;
        }
    }

    // MARK: Starting threads

    /// Starts a new side thread from `parent` with hidden seed context (NEVER passing `parent_session_id` alongside
    /// `messages` on `session.create`), records a durable `BotThreadLink`, listens off-screen, and sends `text`.
    public async Task<string?> StartAsync(
        string text,
        ChatSession parent,
        ChatMessage? anchor,
        string? display = null,
        IReadOnlyList<ChatPart>? attachments = null,
        string? leavingOutLocalId = null,
        string? busyReason = null,
        CancellationToken ct = default)
    {
        var parentId = parent.StoredId;
        var seedSource = parent.Messages.Where(m => m.Id != leavingOutLocalId).ToList();
        var seed = ThreadSeed.Rows(seedSource, parent.Busy || parent.ExternalWorking, (int?)anchor?.RowId, busyReason);
        var extra = new JsonObject
        {
            ["profile"] = parent.Profile,
            ["title"] = ThreadRules.DefaultTitle,
        };
        if (seed.Count > 0) extra["messages"] = ThreadSeed.Params(seed);

        var scope = ScopeKey(parent);
        var entry = new Entry(
            key: "thread-" + Guid.NewGuid().ToString("N"),
            profile: parent.Profile,
            parentScope: scope,
            parentId: string.IsNullOrEmpty(parentId) ? null : parentId,
            storedId: null,
            startedAt: DateTimeOffset.UtcNow)
        {
            AnchorMessageId = anchor?.Id,
            AnchorRow = (int?)anchor?.RowId,
        };

        lock (_gate) _entries.Add(entry);

        ChatSession? live = null;
        string? createdStoredId = null;

        if (ThreadSessionFactory != null)
        {
            createdStoredId = "thread-local-" + Guid.NewGuid().ToString("N")[..8];
            live = ThreadSessionFactory(parent.Profile, createdStoredId, ThreadRules.DefaultTitle, extra);
        }
        else if (Client is { } client)
        {
            try
            {
                var made = await SessionCreate.CallAsync(
                    client.Rpc.RequestAsync, extra, parent.Profile, TimeSpan.FromSeconds(60),
                    folder: string.IsNullOrWhiteSpace(parent.Cwd) ? null : parent.Cwd, ct: ct);
                createdStoredId = made.Text("stored_session_id") ?? made.Text("session_id");
                if (!string.IsNullOrEmpty(createdStoredId))
                    live = client.OpenChat(parent.Profile, createdStoredId, ThreadRules.DefaultTitle);
            }
            catch (Exception e)
            {
                lock (_gate) entry.Problem = e.Message;
                Changed?.Invoke(parent.Profile);
                return entry.Key;
            }
        }
        else
        {
            lock (_gate) entry.Problem = "Not connected to the gateway.";
            Changed?.Invoke(parent.Profile);
            return entry.Key;
        }

        if (live == null || string.IsNullOrEmpty(createdStoredId))
        {
            lock (_gate) entry.Problem = "The gateway didn’t start a new chat.";
            Changed?.Invoke(parent.Profile);
            return entry.Key;
        }

        lock (_gate)
        {
            entry.StoredId = createdStoredId;
            if (_busyThreads.TryGetValue(scope, out var latch) && latch.Key == entry.Key)
                latch.StoredId = createdStoredId;
        }
        if (!string.IsNullOrEmpty(entry.ParentId))
        {
            RecordBotThread(new BotThreadLink(
                createdStoredId, entry.Profile, entry.ParentId,
                entry.StartedAt.ToUnixTimeMilliseconds() / 1000.0, entry.AnchorRow));
        }

        Adopt(live, entry);
        live.ListenOffScreen();
        _ = Task.Run(async () =>
        {
            try { await live.SendAsync(text, ct, display: display); }
            catch (Exception) { }
        }, ct);

        Trim();
        Changed?.Invoke(parent.Profile);
        return entry.Key;
    }

    /// Wires `parent` with all thread callbacks (`OnBusyThreadSend`, `ShouldRouteToBusyThread`,
    /// `ConsumeThreadContextNote`, `RestoreThreadContextNote`, `OnMainReplyLanded`) and external-work unlatching.
    public void WireParent(ChatSession parent)
    {
        if (parent.IsThread) { parent.DisableThreads(); return; }
        parent.OnBusyThreadSend = payload => TakeBusySend(payload, parent);
        parent.ShouldRouteToBusyThread = () => ShouldRouteToBusyThread(parent);
        parent.ConsumeThreadContextNote = () => ConsumeReconciliationNote(parent);
        parent.RestoreThreadContextNote = note => RestoreReconciliationNote(parent, note);
        parent.OnMainReplyLanded = () => NoteMainReplyLanded(parent);
        parent.ExternalWorkChanged += working => NoteMainExternalWork(parent, working);
    }

    // MARK: Busy-chat auto-routing (§9)

    public bool ShouldRouteToBusyThread(ChatSession parent, DateTimeOffset? now = null)
    {
        var scope = ScopeKey(parent);
        lock (_gate)
        {
            if (_optedOutScopes.Contains(scope)) return false;
            if (parent.ExternalWorking) return true;
            return ActiveBusyEntryLocked(parent, scope, now ?? DateTimeOffset.UtcNow) != null;
        }
    }

    public ThreadBusyBanner? BusyBanner(ChatSession parent, string botName, DateTimeOffset? now = null)
    {
        var t = now ?? DateTimeOffset.UtcNow;
        if (!ShouldRouteToBusyThread(parent, t)) return null;
        var scope = ScopeKey(parent);
        lock (_gate)
        {
            if (ActiveBusyEntryLocked(parent, scope, t) is { } active)
            {
                var title = ThreadRules.Name(ToChatThread(active.Entry, null));
                return ThreadRules.ProactiveBanner(botName, title, active.Entry.Key,
                    active.Latch.Reason ?? (parent.ExternalWorking ? OwnerWait.BackgroundTask : null));
            }
            return ThreadRules.ProactiveBanner(botName, null, null,
                parent.ExternalWorking ? OwnerWait.BackgroundTask : null);
        }
    }

    /// User clicked "Use Main" on the proactive busy-thread banner.
    public void OptOutBusyRouting(ChatSession parent)
    {
        var scope = ScopeKey(parent);
        CancelProbe(scope);
        lock (_gate)
        {
            _optedOutScopes.Add(scope);
            _busyThreads.Remove(scope);
        }
        Changed?.Invoke(parent.Profile);
    }

    public void NoteMainExternalWork(ChatSession parent, bool working)
    {
        var scope = ScopeKey(parent);
        if (!working) AutoUnlatch(scope, parent.Profile, parent);
        else Changed?.Invoke(parent.Profile);
    }

    public void NoteMainReplyLanded(ChatSession parent)
    {
        var scope = ScopeKey(parent);
        bool hasState;
        lock (_gate) hasState = _busyThreads.ContainsKey(scope) || _optedOutScopes.Contains(scope);
        if (hasState) AutoUnlatch(scope, parent.Profile, parent);
    }

    private void AutoUnlatch(string scope, string profile, ChatSession? parent)
    {
        CancelProbe(scope);
        BusyLatch? latch;
        lock (_gate)
        {
            _optedOutScopes.Remove(scope);
            _busyThreads.Remove(scope, out latch);
        }
        Changed?.Invoke(profile);
        if (latch == null) return;
        ChatSession? chat = parent;
        if (chat == null && latch.Parent != null) latch.Parent.TryGetTarget(out chat);
        if (chat != null && chat.Observing)
            chat.OnNotice?.Invoke(ThreadRules.BackInMainNotice(chat.EffectiveBotName));
    }

    private void CancelProbe(string scope)
    {
        CancellationTokenSource? cts;
        lock (_gate) _availabilityProbes.Remove(scope, out cts);
        if (cts != null)
        {
            try { cts.Cancel(); } catch (ObjectDisposedException) { }
            cts.Dispose();
        }
    }

    private void StartAvailabilityProbe(string scope, string profile, ChatSession parent, OwnerWait? reason)
    {
        CancelProbe(scope);
        var cts = new CancellationTokenSource();
        lock (_gate) _availabilityProbes[scope] = cts;
        var checkServer = reason?.Kind == OwnerWaitKind.RunningReply;
        var weakParent = new WeakReference<ChatSession>(parent);

        _ = Task.Run(async () =>
        {
            try
            {
                while (!cts.Token.IsCancellationRequested)
                {
                    await Task.Delay(ProbeInterval, cts.Token);
                    if (!weakParent.TryGetTarget(out var p)) break;
                    bool latched;
                    lock (_gate) latched = _busyThreads.ContainsKey(scope);
                    if (!latched) break;
                    if (!p.Observing) continue;
                    if (!p.ExternalWorking) p.CheckExternalWork("busy thread watch");
                    var idle = await p.ProbeMainAvailabilityAsync(checkServer, cts.Token);
                    if (cts.Token.IsCancellationRequested) break;
                    lock (_gate) latched = _busyThreads.ContainsKey(scope);
                    if (!latched) break;
                    if (idle) { AutoUnlatch(scope, profile, p); break; }
                }
            }
            catch (OperationCanceledException) { }
            finally
            {
                lock (_gate)
                {
                    if (_availabilityProbes.TryGetValue(scope, out var cur) && ReferenceEquals(cur, cts))
                        _availabilityProbes.Remove(scope);
                }
            }
        });
    }

    /// Compact summary of settled auto-threads, consumed once on the next main-chat prompt.
    public string? ConsumeReconciliationNote(ChatSession parent)
    {
        var scope = ScopeKey(parent);
        var settled = new List<(string? Title, IReadOnlyList<ChatMessage> Messages)>();
        lock (_gate)
        {
            if (_restoredReconciliation.Remove(scope, out var restored)) return restored;
            if (!_pendingReconciliation.TryGetValue(scope, out var keys) || keys.Count == 0) return null;
            var stillRunning = new List<string>();
            foreach (var key in keys)
            {
                var entry = _entries.FirstOrDefault(e => e.Key == key);
                if (entry == null) continue;
                var view = ToChatThread(entry, null);
                if (view.Running) { stillRunning.Add(key); continue; }
                if (view.Spoken.Count > 0) settled.Add((ThreadRules.Name(view), view.Spoken));
            }
            if (stillRunning.Count == 0) _pendingReconciliation.Remove(scope);
            else _pendingReconciliation[scope] = stillRunning;
        }
        return ThreadContextNote.Format(settled);
    }

    public void RestoreReconciliationNote(ChatSession parent, string note)
    {
        if (string.IsNullOrEmpty(note)) return;
        lock (_gate) _restoredReconciliation[ScopeKey(parent)] = note;
    }

    private (BusyLatch Latch, Entry Entry)? ActiveBusyEntryLocked(ChatSession parent, string scope, DateTimeOffset now)
    {
        if (!_busyThreads.TryGetValue(scope, out var latch)) return null;
        var entry = _entries.FirstOrDefault(e => e.Key == latch.Key || (latch.StoredId != null && e.StoredId == latch.StoredId));
        if (entry == null) return null;
        var reachable = entry.Live != null || entry.StoredId != null;
        var problem = (entry.Live?.ThreadProblem ?? entry.Problem) != null;
        if (!ThreadRules.TakesNextBusySend(latch.HeldAt, parent.AcceptedSends, reachable, problem,
                latch.MainIdleSinceHold, latch.LastActivity, now))
        {
            _busyThreads.Remove(scope);
            return null;
        }
        return (latch, entry);
    }

    private static string SeedBusyReason(OwnerWait? reason, bool externalWorking) => reason?.Kind switch
    {
        OwnerWaitKind.BackgroundTask => "a background task",
        OwnerWaitKind.MessagingTurn => string.IsNullOrWhiteSpace(reason.App) ? "a messaging turn" : $"a {reason.App} message",
        OwnerWaitKind.OtherWindow => "another Hermes window",
        OwnerWaitKind.RunningReply => "another reply",
        _ => externalWorking ? "a background task" : "another turn",
    };

    /// Routes `payload` from a busy `parent` into its active busy thread, or spawns a new one.
    public bool TakeBusySend(BusyThreadPayload payload, ChatSession parent)
    {
        var now = DateTimeOffset.UtcNow;
        var scope = ScopeKey(parent);

        ChatSession? reuseLive = null;
        string? reuseKey = null;
        lock (_gate)
        {
            if (ActiveBusyEntryLocked(parent, scope, now) is { } active)
            {
                reuseKey = active.Entry.Key;
                reuseLive = active.Entry.Live ?? OpenSessionLocked(active.Entry);
                if (reuseLive != null)
                {
                    active.Latch.LastActivity = now;
                    if (payload.Reason != null) active.Latch.Reason = payload.Reason;
                    TrackReconciliationLocked(active.Entry.Key, scope);
                }
            }
        }
        if (reuseLive != null && reuseKey != null)
        {
            reuseLive.ListenOffScreen();
            _ = Task.Run(async () =>
            {
                try { await reuseLive.SendAsync(payload.Text, display: payload.Display); }
                catch (Exception) { }
            });
            Changed?.Invoke(parent.Profile);
            return true;
        }

        if (Client == null && ThreadSessionFactory == null) return false;
        ReleaseOldestIdleIfCrowded();
        var anchor = ThreadRules.BusyAnchor(parent.Messages, payload.LocalId);
        var busyReason = SeedBusyReason(payload.Reason, parent.ExternalWorking);
        var latchReason = payload.Reason ?? (parent.ExternalWorking ? OwnerWait.BackgroundTask : null);

        var placeholderKey = "thread-" + Guid.NewGuid().ToString("N");
        var entry = new Entry(placeholderKey, parent.Profile, scope,
            string.IsNullOrEmpty(parent.StoredId) ? null : parent.StoredId, null, now)
        {
            AnchorMessageId = anchor?.Id,
            AnchorRow = (int?)anchor?.RowId,
        };
        lock (_gate)
        {
            _entries.Add(entry);
            _busyThreads[scope] = new BusyLatch
            {
                Key = placeholderKey,
                HeldAt = parent.AcceptedSends,
                LastActivity = now,
                Reason = latchReason,
                Parent = new WeakReference<ChatSession>(parent),
            };
            _optedOutScopes.Remove(scope);
            TrackReconciliationLocked(placeholderKey, scope);
        }
        StartAvailabilityProbe(scope, parent.Profile, parent, latchReason);

        var seedSource = parent.Messages.Where(m => m.Id != payload.LocalId).ToList();
        var seed = ThreadSeed.Rows(seedSource, parent.Busy || parent.ExternalWorking, (int?)anchor?.RowId, busyReason);
        var extra = new JsonObject
        {
            ["profile"] = parent.Profile,
            ["title"] = ThreadRules.DefaultTitle,
        };
        if (seed.Count > 0) extra["messages"] = ThreadSeed.Params(seed);

        _ = Task.Run(async () =>
        {
            ChatSession? live = null;
            string? storedId = null;
            string? failure = null;
            if (ThreadSessionFactory != null)
            {
                storedId = "thread-local-" + Guid.NewGuid().ToString("N")[..8];
                live = ThreadSessionFactory(parent.Profile, storedId, ThreadRules.DefaultTitle, extra);
            }
            else if (Client is { } client)
            {
                try
                {
                    var made = await SessionCreate.CallAsync(
                        client.Rpc.RequestAsync, extra, parent.Profile, TimeSpan.FromSeconds(60),
                        folder: string.IsNullOrWhiteSpace(parent.Cwd) ? null : parent.Cwd);
                    storedId = made.Text("stored_session_id") ?? made.Text("session_id");
                    if (!string.IsNullOrEmpty(storedId))
                        live = client.OpenChat(parent.Profile, storedId, ThreadRules.DefaultTitle);
                }
                catch (Exception e) { failure = e.Message; }
            }

            if (live == null || string.IsNullOrEmpty(storedId))
            {
                lock (_gate)
                {
                    _entries.Remove(entry);
                    if (_busyThreads.TryGetValue(scope, out var l) && l.Key == placeholderKey) _busyThreads.Remove(scope);
                }
                Changed?.Invoke(parent.Profile);
                parent.ThreadSendCameBack(payload.Display ?? payload.Text, failure ?? "The gateway didn’t start a new chat.");
                return;
            }

            lock (_gate)
            {
                entry.StoredId = storedId;
                if (_busyThreads.TryGetValue(scope, out var l) && l.Key == placeholderKey) l.StoredId = storedId;
            }
            if (!string.IsNullOrEmpty(entry.ParentId))
            {
                RecordBotThread(new BotThreadLink(
                    storedId, entry.Profile, entry.ParentId,
                    entry.StartedAt.ToUnixTimeMilliseconds() / 1000.0, entry.AnchorRow));
            }

            Adopt(live, entry);
            live.DraftReturned += (returnedText, why) =>
            {
                if (live.Observing || live.AcceptedSends > 0) return;
                lock (_gate)
                {
                    if (entry.StoredId == null)
                    {
                        _entries.Remove(entry);
                        if (_busyThreads.TryGetValue(scope, out var l) && l.Key == entry.Key) _busyThreads.Remove(scope);
                    }
                }
                Changed?.Invoke(entry.Profile);
                parent.ThreadSendCameBack(returnedText, why);
            };
            live.ListenOffScreen();
            try { await live.SendAsync(payload.Text, display: payload.Display); }
            catch (Exception) { }
            Changed?.Invoke(parent.Profile);
        });

        Changed?.Invoke(parent.Profile);
        return true;
    }

    private void TrackReconciliationLocked(string key, string scope)
    {
        if (!_pendingReconciliation.TryGetValue(scope, out var list))
            _pendingReconciliation[scope] = list = [];
        if (!list.Contains(key)) list.Add(key);
        if (list.Count > 4) list.RemoveRange(0, list.Count - 4);
    }

    private void Adopt(ChatSession live, Entry entry)
    {
        lock (_gate) entry.Live = live;
        live.IsThread = true;
        live.DisableThreads();
        live.ThreadHold = true;
        live.OnThreadChange = () =>
        {
            var msgs = live.Messages;
            var hash = new HashCode();
            hash.Add(msgs.Count);
            if (msgs.Count > 0)
            {
                var last = msgs[^1];
                hash.Add(last.Id);
                hash.Add(last.Revision);
                hash.Add(last.IsStreaming);
            }
            hash.Add(live.Busy);
            hash.Add(live.Title);
            hash.Add(live.StoredId);
            hash.Add(live.ThreadProblem);
            var h = hash.ToHashCode();
            var changed = false;
            lock (_gate)
            {
                if (!ReferenceEquals(entry.Live, live) || h == entry.DrawnHash) return;
                entry.DrawnHash = h;
                entry.LastChange = DateTimeOffset.UtcNow;
                if (entry.StoredId == null && !string.IsNullOrEmpty(live.StoredId)) entry.StoredId = live.StoredId;
                changed = true;
            }
            if (changed)
            {
                Changed?.Invoke(entry.Profile);
                if (!live.Busy) Trim();
            }
        };
    }

    // MARK: Opening & Lifecycle

    public ChatSession? GetOrOpenSession(string key)
    {
        Entry? entry;
        lock (_gate)
        {
            entry = _entries.FirstOrDefault(e => e.Key == key);
            if (entry == null) return null;
            if (entry.Live != null) return entry.Live;
            var opened = OpenSessionLocked(entry);
            if (opened == null) return null;
            entry.Live = opened;
        }
        Adopt(entry.Live!, entry);
        Trim();
        return entry.Live;
    }

    private ChatSession? OpenSessionLocked(Entry entry)
    {
        if (string.IsNullOrEmpty(entry.StoredId)) return null;
        var title = ThreadRules.Name(ToChatThread(entry, null));
        if (ThreadSessionFactory != null)
            return ThreadSessionFactory(entry.Profile, entry.StoredId, title, new JsonObject());
        return Client?.OpenChat(entry.Profile, entry.StoredId, title);
    }

    public string? Name(string key)
    {
        lock (_gate)
            return _entries.FirstOrDefault(e => e.Key == key) is { } e ? ThreadRules.Name(ToChatThread(e, null)) : null;
    }

    public bool IsDrawn(string? storedId, string profile, ChatSession? focused, string? canonicalSessionId = null)
    {
        if (string.IsNullOrEmpty(storedId) || focused == null || !focused.SupportsThreads || focused.Profile != profile)
            return false;
        var ids = ParentIds(focused, canonicalSessionId);
        lock (_gate)
        {
            return _entries.Any(e =>
                e.Profile == profile && Belongs(e, ids, focused.IsBotChat)
                && (e.StoredId == storedId || e.Live?.StoredId == storedId));
        }
    }

    private void ReleaseOldestIdleIfCrowded()
    {
        Entry? oldest = null;
        lock (_gate)
        {
            var idle = _entries.Where(e => e.Live is { Busy: false, Observing: false }).OrderBy(e => e.LastChange).ToList();
            if (idle.Count >= IdleLive) oldest = idle[0];
        }
        if (oldest != null) Release(oldest);
    }

    private void Trim()
    {
        List<Entry> excess;
        lock (_gate)
        {
            excess = [.. _entries
                .Where(e => e.Live is { Busy: false, Observing: false })
                .OrderByDescending(e => e.LastChange)
                .Skip(IdleLive)];
        }
        foreach (var e in excess) Release(e);
    }

    private void Release(Entry entry)
    {
        ChatSession? live;
        lock (_gate)
        {
            live = entry.Live;
            if (live == null) return;
            entry.Kept = [.. live.Messages];
            if (entry.StoredId == null && !string.IsNullOrEmpty(live.StoredId)) entry.StoredId = live.StoredId;
            entry.Problem = live.ThreadProblem;
            entry.Live = null;
        }
        live.OnThreadChange = null;
        live.EndThreadHold();
    }

    /// Sign-out or gateway switch: clears all runtime thread state and stops availability probes.
    public void Reset()
    {
        List<ChatSession> lives;
        List<CancellationTokenSource> probes;
        lock (_gate)
        {
            lives = [.. _entries.Select(e => e.Live).OfType<ChatSession>()];
            probes = [.. _availabilityProbes.Values];
            _entries.Clear();
            _busyThreads.Clear();
            _optedOutScopes.Clear();
            _availabilityProbes.Clear();
            _pendingReconciliation.Clear();
            _restoredReconciliation.Clear();
        }
        foreach (var live in lives) { live.OnThreadChange = null; live.ThreadHold = false; }
        foreach (var cts in probes) { try { cts.Cancel(); } catch (ObjectDisposedException) { } cts.Dispose(); }
    }
}
