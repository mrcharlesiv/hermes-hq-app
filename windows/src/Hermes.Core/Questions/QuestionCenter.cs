using System.Text.Json.Nodes;
using Hermes.Core.Net;
using Hermes.Core.Rpc;

namespace Hermes.Core.Questions;

/// The account's open server→client requests (HermesKit/Chat/ServerRequests.swift `ServerRequestCenter`, spec 1x
/// §3.2–§3.5): every approval, question and password prompt the gateway asked this app, answered exactly once. One per
/// account (HermesClient.Questions); chats read their slice through a ChatQuestions link. Thread-safe: state sits
/// behind one lock and listeners are told after it is released, on whichever thread made the change (the UI marshals).
/// Typed answers never leave memory (Q15): drafts are dropped on answer, cancel and sign-out, and nothing is logged.
///
/// Not ported yet: late logins (a vault.save_login the bot stopped waiting for, saved later with vault.add) and the
/// preview tab's preview.read (declined like the other window-owned methods).
public sealed class QuestionCenter : IDisposable
{
    public sealed record Timing
    {
        public TimeSpan ProbeDebounce { get; init; } = TimeSpan.FromMilliseconds(750);
        /// Entries no resume/activate/replay named within this long of a new socket's ready are dropped (rule 7).
        public TimeSpan StaleDrop { get; init; } = TimeSpan.FromSeconds(15);
        /// A running clarify tool with no question this long after its tool.start is probed (§3.5).
        public TimeSpan UndeliveredAfter { get; init; } = TimeSpan.FromSeconds(4);
        /// An answered approval card fades out this long before it goes (§4.2).
        public TimeSpan Leaving { get; init; } = TimeSpan.FromMilliseconds(200);
        public TimeSpan ApprovalRespondTimeout { get; init; } = TimeSpan.FromSeconds(330);
        public TimeSpan LockTimeout { get; init; } = TimeSpan.FromSeconds(30);
        public TimeSpan RecentlyAnsweredTtl { get; init; } = TimeSpan.FromMinutes(10);
        public TimeSpan TimeoutCacheTtl { get; init; } = TimeSpan.FromMinutes(5);
        public static readonly Timing Standard = new();
    }

    private enum EntryState { Open, Answering, Leaving }

    private sealed record SharedPrompt(string PromptId, long Generation);

    /// One open srq, or a queue-backed approval with no srq (SrqOpen false, id "queue:<request_id>").
    private sealed class Entry
    {
        public required string Id;
        public required PromptKind Kind;
        public required string SessionId;
        public required JsonObject Params;
        public bool SrqOpen;
        public string? QueueRequestId;
        public long DeliveredSeq;
        public int Epoch;
        public DateTimeOffset FirstSeen;
        public EntryState State = EntryState.Open;
        public ApprovalChoice? Answering;
        /// The ready generation that still has to confirm it (rule 7); null = confirmed.
        public int? UnconfirmedSince;
        /// A session authority's shared question (clarify.request), answered with clarify.respond.
        public SharedPrompt? Prompt;
    }

    private sealed record Runtime(string Profile, string? StoredId);
    private sealed class Answered { public required string Id; public DateTimeOffset At; public int? Epoch; }

    public static readonly IReadOnlySet<string> WindowOwned =
        new HashSet<string> { "terminal.read", "preview.read", "window.read", "preview.act", "tour" };
    public const int NotShownCode = 4404;
    public const string NotShownMessage = "This window is not showing the session.";
    public const int RuntimeCap = 256;

    public const string ApprovalOffline = "Hermes is offline right now. The command is still waiting for your answer (until the approval timeout). Reconnect, then send it again.";
    public const string ApprovalFailed = "Couldn’t send your answer.";
    public const string Offline = "Hermes is offline right now. Reconnect, then send it again.";
    public const string ClarifyFailed = "Couldn’t send your answers.";

    public static string ValueFailed(PromptKind kind) => kind switch
    {
        PromptKind.Sudo => "Couldn’t send the sudo password.",
        PromptKind.Secret => "Couldn’t send the secret.",
        PromptKind.VaultUnlock => "Couldn’t send the master password.",
        PromptKind.VaultSaveLogin => "Couldn’t save the login.",
        PromptKind.VaultCode => "Couldn’t send the code.",
        _ => ApprovalFailed,
    };

    private readonly IQuestionTransport _transport;
    private readonly Timing _timing;
    private readonly object _gate = new();
    private readonly List<Entry> _entries = [];
    private readonly Dictionary<string, Runtime> _runtimes = [];
    private readonly List<string> _runtimeOrder = [];
    private readonly List<Answered> _recentlyAnswered = [];
    private readonly Dictionary<string, ClarifyDraft> _drafts = [];
    private readonly List<(string Key, DateTimeOffset At)> _approvalSeen = [];
    private readonly Dictionary<string, int> _stackSize = [];
    private readonly Dictionary<string, SentClarify> _sent = [];
    private readonly HashSet<string> _undelivered = [];
    private readonly HashSet<string> _liveTurns = [];
    private readonly Dictionary<string, int> _approvalsRevision = [];
    private readonly Dictionary<string, (NeedsInput Kind, string? StoredId)> _toldNeeds = [];
    private readonly Dictionary<string, CancellationTokenSource> _probeTasks = [];
    private readonly HashSet<string> _probing = [];
    private readonly Dictionary<string, CancellationTokenSource> _clarifyWatch = [];
    private readonly Dictionary<string, (TimeSpan Value, DateTimeOffset At)> _timeouts = [];
    private readonly List<ChatQuestions> _links = [];
    private readonly HashSet<string> _dirty = [];
    private HashSet<string> _knownIds = [];
    private CancellationTokenSource? _staleTask;
    private readonly CancellationTokenSource _life = new();
    private long _seq;
    private int _readyGeneration;
    private bool _shutDown;

    public Func<DateTimeOffset> Now { get; set; } = () => DateTimeOffset.UtcNow;

    /// A session's needs-input changed (Bots row, spec 1x §3.6): its runtime id, profile, stored id and kind (null =
    /// nothing waits). Told again for the same runtime when its stored id becomes known while it waits.
    public event Action<string, string, string?, NeedsInput?>? NeedsInputChanged;
    /// Requests that went (answered, withdrawn, pruned, signed out): kept password sheets drop theirs and their text.
    public event Action<IReadOnlySet<string>>? Removed;
    /// A request reached the app for the first time (its chat may be off screen): its id, kind, runtime id and profile.
    public event Action<string, PromptKind, string, string?>? Arrived;
    /// An approval of `session` timed out (request.cancel reason timeout).
    public event Action<string>? ApprovalTimedOut;

    public QuestionCenter(IQuestionTransport transport, Timing? timing = null)
    {
        _transport = transport;
        _timing = timing ?? Timing.Standard;
    }

    /// Wires the centre to the account's socket. Every listener runs on the socket's thread, in frame order.
    public void Attach(RpcConnection rpc)
    {
        rpc.Event += Receive;
        rpc.ServerRequest += Delivered;
        rpc.OpenRequests += Authoritative;
        rpc.Reconnected += _ => SocketReady();
    }

    public bool Connected => _transport.Connected;
    public void ReconnectNow() => _transport.ReconnectNow();

    // ------------------------------------------------------------------ chats

    /// A chat's link (its runtime ids, whether it is on screen, its change callback).
    public ChatQuestions Link(string profile)
    {
        var link = new ChatQuestions(this, profile);
        lock (_gate) _links.Add(link);
        return link;
    }

    internal void Unlink(ChatQuestions link)
    {
        lock (_gate) _links.Remove(link);
    }

    private IEnumerable<ChatQuestions> LinksFor(string session) => _links.Where(l => l.Covers(session)).ToList();

    /// A chat bound a runtime id (rule 8: entries under its previous runtime go).
    internal void Bound(string runtime, string? previous, string profile, string? storedId)
    {
        lock (_gate)
        {
            _runtimes[runtime] = new Runtime(profile, storedId);
            _runtimeOrder.Remove(runtime);
            _runtimeOrder.Add(runtime);
            EvictRuntimes();
            if (previous != null && previous != runtime)
            {
                var old = _entries.Where(e => e.SessionId == previous).ToList();
                if (old.Count > 0)
                {
                    _entries.RemoveAll(e => e.SessionId == previous);
                    foreach (var e in old) _drafts.Remove(e.Id);
                    BumpApprovals(previous);
                    Changed(previous);
                }
                if (_sent.Remove(previous) | _undelivered.Remove(previous)) Changed(previous);
            }
            Changed(runtime);
        }
        Flush();
    }

    private void EvictRuntimes()
    {
        if (_runtimes.Count <= RuntimeCap) return;
        var live = _links.SelectMany(l => l.SessionIds).Concat(_entries.Select(e => e.SessionId)).ToHashSet();
        var i = 0;
        while (_runtimes.Count > RuntimeCap && i < _runtimeOrder.Count)
        {
            var id = _runtimeOrder[i];
            if (live.Contains(id)) { i++; continue; }
            _runtimes.Remove(id);
            _runtimeOrder.RemoveAt(i);
        }
    }

    // ------------------------------------------------------------------ reads

    /// One chat's view: the requests of its runtime ids (oldest first).
    public ChatPrompts PromptsFor(IReadOnlyCollection<string> sessions)
    {
        lock (_gate) return PromptsLocked(sessions);
    }

    private ChatPrompts PromptsLocked(IReadOnlyCollection<string> sessions)
    {
        var set = sessions.ToHashSet();
        var approvals = new List<ApprovalPrompt>();
        var values = new List<ValuePrompt>();
        ClarifyPrompt? clarify = null;
        foreach (var e in _entries.Where(e => set.Contains(e.SessionId)))
        {
            switch (e.Kind)
            {
                case PromptKind.Approval: approvals.Add(ApprovalFrom(e)); break;
                case PromptKind.Clarify:
                    clarify ??= new ClarifyPrompt(e.Id, ClarifyText.Normalize(e.Params.Get("questions")),
                        ClarifyText.LockedAnswers(e.Params.Get("answers")), e.State == EntryState.Answering);
                    break;
                default: values.Add(new ValuePrompt(e.Id, e.Kind, e.Params, e.State != EntryState.Open)); break;
            }
        }
        var total = 0;
        SentClarify? sent = null;
        var undelivered = false;
        foreach (var s in sessions)
        {
            total = Math.Max(total, _stackSize.GetValueOrDefault(s));
            sent ??= _sent.GetValueOrDefault(s);
            if (_undelivered.Contains(s) && clarify == null) undelivered = true;
        }
        return new ChatPrompts
        {
            Approvals = approvals, ApprovalStackTotal = Math.Max(total, approvals.Count), Clarify = clarify,
            SentClarify = sent, ClarifyUndelivered = undelivered, Values = values,
        };
    }

    public ClarifyDraft? Draft(string requestId)
    {
        lock (_gate) return _drafts.GetValueOrDefault(requestId);
    }

    public void SaveDraft(string requestId, ClarifyDraft draft)
    {
        lock (_gate)
            if (_entries.Any(e => e.Id == requestId)) _drafts[requestId] = draft;
    }

    /// Every runtime id that waits on the user now, with what it waits for (the Bots rows' first read).
    public IReadOnlyDictionary<string, NeedsInput> Waiting()
    {
        lock (_gate)
            return _entries.Select(e => e.SessionId).Distinct()
                .Select(s => (s, PromptsLocked([s]).NeedsInput)).Where(x => x.NeedsInput != null)
                .ToDictionary(x => x.s, x => x.NeedsInput!.Value);
    }

    private static ApprovalPrompt ApprovalFrom(Entry e)
    {
        var p = e.Params;
        var choices = p.Arr("choices")?.Select(J.AsString).Where(c => c != null).ToList()
            ?? (p.Bool("smart_denied") == true ? ["once", "deny"] : null);
        var allowSession = choices?.Contains("session") ?? true;
        var allowAlways = choices?.Contains("always") ?? p.Bool("allow_permanent") != false;
        return new ApprovalPrompt(e.Id, p.Str("command") ?? "", p.Str("description") ?? "", allowSession, allowAlways,
            ClockKey(e), e.FirstSeen, e.Answering, e.State == EntryState.Leaving);
    }

    private static string ClockKey(Entry e) => e.QueueRequestId is { Length: > 0 } r ? r : $"rpc:{e.Id}";

    /// When an approval first reached the app (a replay keeps the first time). Capped at 64 keys.
    private DateTimeOffset SeenAt(string key)
    {
        foreach (var (k, at) in _approvalSeen) if (k == key) return at;
        var now = Now();
        _approvalSeen.Add((key, now));
        if (_approvalSeen.Count > 64) _approvalSeen.RemoveAt(0);
        return now;
    }

    // ------------------------------------------------------------------ events

    /// Every event frame (and the replayed ones).
    public void Receive(RpcEvent ev)
    {
        lock (_gate)
        {
            if (_shutDown) return;
            _seq++;
            var session = ev.SessionId;
            var name = ev.Payload.Str("name");
            switch (ev.Type)
            {
                case "request.cancel": Withdrawn(ev); break;
                case "clarify.request": PromptAsked(ev); break;
                case "clarify.settled": PromptSettled(ev); break;
                case "approval.cancelled": ApprovalsCancelled(ev); break;
                case "message.start":
                    _liveTurns.Add(session);
                    AgentMovedOn(session);
                    break;
                case "message.delta":
                    _liveTurns.Add(session);
                    break;
                case "tool.start":
                    _liveTurns.Add(session);
                    if (name == "clarify") WatchClarify(session);
                    break;
                case "tool.complete":
                    if (name == "clarify") ClarifySettled(session);
                    AgentMovedOn(session);
                    break;
                case "message.complete" or "error":
                    if (session.Length == 0) break;
                    if (ev.Type == "message.complete") DropSharedPrompts(session);
                    TurnEnded(session);
                    ClarifySettled(session);
                    AgentMovedOn(session);
                    break;
                case "session.info":
                    var running = ev.Payload.Bool("running");
                    if (running == true) _liveTurns.Add(session);
                    else if (running == false && _liveTurns.Contains(session)) TurnEnded(session);
                    // Rule 3: the queue is replayed for a chat on screen (a queue-only approval has no srq to announce it).
                    if (_entries.Any(e => e.SessionId == session && e.Kind == PromptKind.Approval)
                        || LinksFor(session).Any(l => l.Observing)) ReplayApprovals(session);
                    break;
            }
        }
        Flush();
    }

    /// Rule 1: a request (live, or re-delivered from open_requests).
    public void Delivered(ServerRequest r)
    {
        lock (_gate)
        {
            if (_shutDown) return;
            _seq++;
            DeliveredLocked(r);
        }
        Flush();
    }

    private void DeliveredLocked(ServerRequest r)
    {
        var parameters = r.Params;
        var session = r.SessionId.Length > 0 ? r.SessionId : parameters.Str("session_id") ?? "";
        if (AlreadyAnswered(r.Id, r.Epoch)) return;
        if (WindowOwned.Contains(r.Method))
        {
            // Q3: no pane here. A decline is one client's vote; with no decline support, stay silent.
            if (_transport.DeclinesNotShown) SendError(r.Id, NotShownCode, NotShownMessage);
            return;
        }
        if (PromptKinds.FromMethod(r.Method) is not { } kind)
        {
            // Q4: setup_choose, display.install.sudo, anything new.
            SendError(r.Id, -32601, $"no handler for server request: {r.Method}");
            return;
        }
        if (!_entries.Any(e => e.Id == r.Id) && LinksFor(session).Any(l => l.TurnInterrupted))
        {
            // The user already stopped this turn: refuse rather than park a card for a dead turn (§2.3).
            if (kind == PromptKind.Clarify) SendResult(r.Id, new JsonObject());
            else SendError(r.Id, -32603, "session interrupted");
            return;
        }
        if (kind == PromptKind.Clarify && ClarifyText.Normalize(parameters.Get("questions")).Count == 0)
        {
            SendResult(r.Id, new JsonObject());
            return;
        }
        var queueRequest = kind == PromptKind.Approval && parameters.Str("request_id") is { Length: > 0 } q ? q : null;
        var i = _entries.FindIndex(e => e.Id == r.Id);
        if (i >= 0)
        {
            // Same request again: keep its UI state, take the new params (a replay may add clarify answers).
            var e = _entries[i];
            e.Params = parameters;
            e.Epoch = r.Epoch;
            e.SrqOpen = true;
            e.UnconfirmedSince = null;
            e.DeliveredSeq = _seq;
        }
        else if (queueRequest != null && _entries.FindIndex(e => !e.SrqOpen && e.QueueRequestId == queueRequest) is var k and >= 0)
        {
            // The live request replaces a restored queue-only copy (never the other way round).
            var old = _entries[k];
            _entries[k] = new Entry
            {
                Id = r.Id, Kind = kind, SessionId = session, Params = parameters, SrqOpen = true, QueueRequestId = queueRequest,
                DeliveredSeq = _seq, Epoch = r.Epoch, FirstSeen = old.FirstSeen, State = old.State, Answering = old.Answering,
            };
        }
        else
        {
            var entry = new Entry
            {
                Id = r.Id, Kind = kind, SessionId = session, Params = parameters, SrqOpen = true, QueueRequestId = queueRequest,
                DeliveredSeq = _seq, Epoch = r.Epoch, FirstSeen = Now(),
            };
            if (kind == PromptKind.Approval)
            {
                entry.FirstSeen = SeenAt(ClockKey(entry));
                _stackSize[session] = _stackSize.GetValueOrDefault(session) + 1;
                BumpApprovals(session);
            }
            if (kind == PromptKind.Clarify)
            {
                _undelivered.Remove(session);
                CancelClarifyWatch(session);
                _sent.Remove(session);
            }
            _entries.Add(entry);
            var profile = _runtimes.GetValueOrDefault(session)?.Profile;
            _arrived.Add((entry.Id, kind, session, profile));
        }
        Changed(session);
    }

    private readonly List<(string, PromptKind, string, string?)> _arrived = [];

    /// [authority] A session authority's shared question: one clarify.request event per question.
    private void PromptAsked(RpcEvent ev)
    {
        var p = ev.Payload;
        var session = ev.SessionId;
        if (p.Text("prompt_id") is not { } promptId || p.Int("execution_generation") is not { } generation
            || session.Length == 0 || AlreadyAnswered(promptId, 0)) return;
        if (_entries.FirstOrDefault(e => e.Id == promptId) is { } known) { known.UnconfirmedSince = null; return; }
        var prompt = new SharedPrompt(promptId, generation);
        var question = new JsonObject
        {
            ["qid"] = promptId, ["question"] = p.Get("question")?.DeepClone(),
            ["choices"] = p.Get("choices")?.DeepClone() ?? new JsonArray(),
            ["multi_select"] = p.Get("multi_select")?.DeepClone() ?? false,
        };
        var parameters = new JsonObject { ["session_id"] = session, ["questions"] = new JsonArray(question) };
        if (LinksFor(session).Any(l => l.TurnInterrupted) || ClarifyText.Normalize(parameters.Get("questions")).Count == 0)
        {
            _ = SharedRespondAsync(promptId, session, prompt, "").ContinueWith(_ => { }, TaskScheduler.Default);
            return;
        }
        _undelivered.Remove(session);
        CancelClarifyWatch(session);
        _sent.Remove(session);
        _entries.Add(new Entry
        {
            Id = promptId, Kind = PromptKind.Clarify, SessionId = session, Params = parameters, SrqOpen = false,
            DeliveredSeq = _seq, FirstSeen = Now(), Prompt = prompt,
        });
        _arrived.Add((promptId, PromptKind.Clarify, session, _runtimes.GetValueOrDefault(session)?.Profile));
        Changed(session);
    }

    private void PromptSettled(RpcEvent ev)
    {
        if (ev.Payload.Str("prompt_id") is not { } id) return;
        var i = _entries.FindIndex(e => e.Id == id && e.Prompt != null);
        if (i < 0 || _entries[i].State != EntryState.Open) return;
        var entry = _entries[i];
        _entries.RemoveAt(i);
        _drafts.Remove(id);
        Changed(entry.SessionId);
    }

    private void DropSharedPrompts(string session)
    {
        var gone = _entries.Where(e => e.SessionId == session && e.Prompt != null && e.State == EntryState.Open).ToList();
        if (gone.Count == 0) return;
        foreach (var e in gone) { _entries.Remove(e); _drafts.Remove(e.Id); }
        Changed(session);
    }

    /// Rule 2: the authoritative set for one session.
    public void Authoritative(OpenRequests o)
    {
        lock (_gate)
        {
            if (_shutDown || o.SessionId.Length == 0) return;
            _seq++;
            var session = o.SessionId;
            var ids = o.Ids.ToHashSet();
            var pending = o.PendingApproval;
            var promptIds = o.PromptIds?.ToHashSet();
            var changedAny = false;
            var kept = new List<Entry>();
            foreach (var entry in _entries)
            {
                if (entry.SessionId != session) { kept.Add(entry); continue; }
                if (entry.Prompt != null)
                {
                    if (promptIds != null)
                    {
                        if (!promptIds.Contains(entry.Id)) { _drafts.Remove(entry.Id); changedAny = true; continue; }
                        entry.UnconfirmedSince = null;
                    }
                    kept.Add(entry);
                    continue;
                }
                if (entry.SrqOpen)
                {
                    if (ids.Contains(entry.Id)) entry.UnconfirmedSince = null;
                    else if (entry.DeliveredSeq < _seq)
                    {
                        // Answered or withdrawn elsewhere (no event reaches us when another app answers first, §2.5).
                        _drafts.Remove(entry.Id);
                        if (entry.Kind == PromptKind.Approval) BumpApprovals(session);
                        changedAny = true;
                        continue;
                    }
                }
                else if (o.Method != "session.events.since")
                {
                    // A queue-only approval: confirmed by pending_approval, else gone (resume/activate only).
                    if (pending != null && pending.Str("request_id") == entry.QueueRequestId) entry.UnconfirmedSince = null;
                    else
                    {
                        BumpApprovals(session);
                        changedAny = true;
                        continue;
                    }
                }
                kept.Add(entry);
            }
            _entries.Clear();
            _entries.AddRange(kept);
            if (pending?.Str("request_id") is { Length: > 0 } request && !_entries.Any(e => e.QueueRequestId == request))
            {
                AddQueueOnly(session, pending);
                changedAny = true;
            }
            if (changedAny) Changed(session);
            // A reconnect's session.activate / session.resume confirmed the runtime: the chat on screen reads the
            // approval queue now (rule 3, "approvalsConfirmed").
            if (o.Method is "session.activate" or "session.resume" && LinksFor(session).Any(l => l.Observing))
                ReplayApprovals(session);
        }
        Flush();
    }

    private void AddQueueOnly(string session, JsonObject approval)
    {
        if (approval.Str("request_id") is not { Length: > 0 } request) return;
        var id = $"queue:{request}";
        if (_recentlyAnswered.Any(a => a.Id == id)) return;
        var parameters = (JsonObject)approval.DeepClone();
        parameters["session_id"] = session;
        var entry = new Entry
        {
            Id = id, Kind = PromptKind.Approval, SessionId = session, Params = parameters, SrqOpen = false,
            QueueRequestId = request, DeliveredSeq = _seq, FirstSeen = SeenAt(request),
        };
        _entries.Add(entry);
        _stackSize[session] = _stackSize.GetValueOrDefault(session) + 1;
        BumpApprovals(session);
        _arrived.Add((id, PromptKind.Approval, session, _runtimes.GetValueOrDefault(session)?.Profile));
    }

    /// Rule 7: a new socket. Older entries stay on screen until a resume/activate/replay confirms or prunes them; those
    /// none names within 15 s go (they come back on that chat's next resume).
    public void SocketReady()
    {
        lock (_gate)
        {
            if (_shutDown) return;
            var generation = ++_readyGeneration;
            foreach (var e in _entries) e.UnconfirmedSince ??= generation;
            _staleTask?.Cancel();
            var cts = _staleTask = CancellationTokenSource.CreateLinkedTokenSource(_life.Token);
            _ = After(_timing.StaleDrop, cts.Token, () => DropUnconfirmed(generation));
        }
    }

    private void DropUnconfirmed(int generation)
    {
        lock (_gate)
        {
            var stale = _entries.Where(e => (e.UnconfirmedSince ?? int.MaxValue) <= generation).ToList();
            if (stale.Count == 0) return;
            foreach (var e in stale) { _entries.Remove(e); _drafts.Remove(e.Id); }
            foreach (var session in stale.Select(e => e.SessionId).Distinct())
            {
                BumpApprovals(session);
                Changed(session);
            }
        }
        Flush();
    }

    /// Rule 4: request.cancel.
    private void Withdrawn(RpcEvent ev)
    {
        if (ev.Payload.Str("id") is not { } id) return;
        var i = _entries.FindIndex(e => e.Id == id);
        if (i < 0) return;
        var entry = _entries[i];
        _entries.RemoveAt(i);
        _drafts.Remove(id);
        if (entry.Kind == PromptKind.Approval)
        {
            BumpApprovals(entry.SessionId);
            if (ev.Payload.Str("reason") == "timeout") _timedOut.Add(entry.SessionId);
        }
        Changed(entry.SessionId);
    }

    private readonly List<string> _timedOut = [];

    /// Rule 5: approval.cancelled (Stop deny-resolves every queued approval).
    private void ApprovalsCancelled(RpcEvent ev)
    {
        var requests = (ev.Payload.Arr("request_ids") ?? []).Select(J.AsString).Where(s => s != null).ToHashSet();
        if (requests.Count == 0) return;
        var gone = _entries.Where(e => e.Kind == PromptKind.Approval && e.QueueRequestId != null && requests.Contains(e.QueueRequestId)).ToList();
        if (gone.Count == 0) return;
        foreach (var e in gone) _entries.Remove(e);
        foreach (var s in gone.Select(e => e.SessionId).Distinct())
        {
            BumpApprovals(s);
            Changed(s);
        }
    }

    /// Rule 6: the turn ended. A queue-only approval goes now (and the queue is read again). A request with an open srq
    /// stays until a probe's authoritative open_requests confirms or prunes it.
    private void TurnEnded(string session)
    {
        _liveTurns.Remove(session);
        var queueOnly = _entries.Where(e => e.SessionId == session && e.Kind == PromptKind.Approval && !e.SrqOpen
            && e.State == EntryState.Open).ToList();
        if (queueOnly.Count > 0)
        {
            foreach (var e in queueOnly) _entries.Remove(e);
            BumpApprovals(session);
            Changed(session);
            ReplayApprovals(session);
        }
        if (_entries.Any(e => e.SessionId == session && e.SrqOpen)) ProbeSoon(session);
    }

    /// The tool, the reply or the turn moved on after a request was delivered: maybe it was answered elsewhere (§3.5).
    private void AgentMovedOn(string session)
    {
        if (!_entries.Any(e => e.SessionId == session && e.SrqOpen && e.DeliveredSeq < _seq)) return;
        ProbeSoon(session);
        if (_entries.Any(e => e.SessionId == session && e.Kind == PromptKind.Approval)) ReplayApprovals(session);
    }

    private void ClarifySettled(string session)
    {
        CancelClarifyWatch(session);
        if (_sent.Remove(session) | _undelivered.Remove(session)) Changed(session);
    }

    private void CancelClarifyWatch(string session)
    {
        if (_clarifyWatch.Remove(session, out var cts)) cts.Cancel();
    }

    // ------------------------------------------------------------------ probe (§2.4, §3.5)

    /// session.events.since with the highest last_seen: no events, the authoritative open_requests (pruned by rule 2
    /// through the connection's interception). Debounced, one in flight per session.
    public void ProbeSoon(string session)
    {
        lock (_gate)
        {
            if (session.Length == 0 || _probeTasks.ContainsKey(session)) return;
            var cts = CancellationTokenSource.CreateLinkedTokenSource(_life.Token);
            _probeTasks[session] = cts;
            _ = After(_timing.ProbeDebounce, cts.Token, () =>
            {
                lock (_gate) _probeTasks.Remove(session);
                _ = ProbeAsync(session);
            });
        }
    }

    public async Task ProbeAsync(string session)
    {
        JsonObject parameters;
        lock (_gate)
        {
            if (!_probing.Add(session)) return;
            parameters = new JsonObject { ["session_id"] = session, ["last_seen"] = 2147483647 };
            if (_runtimes.GetValueOrDefault(session)?.Profile is { } profile) parameters["profile"] = profile;
        }
        try { await _transport.CallAsync("session.events.since", parameters, TimeSpan.FromSeconds(10)); }
        catch (GatewayException) { }
        finally { lock (_gate) _probing.Remove(session); }
    }

    /// A clarify tool started: if no question reaches us within 4 s, probe; still none → "didn't reach the app".
    private void WatchClarify(string session)
    {
        if (_entries.Any(e => e.SessionId == session && e.Kind == PromptKind.Clarify)) return;
        CancelClarifyWatch(session);
        var cts = CancellationTokenSource.CreateLinkedTokenSource(_life.Token);
        _clarifyWatch[session] = cts;
        _ = After(_timing.UndeliveredAfter, cts.Token, async () =>
        {
            lock (_gate)
                if (_entries.Any(e => e.SessionId == session && e.Kind == PromptKind.Clarify)) return;
            await ProbeAsync(session);
            lock (_gate)
            {
                if (cts.IsCancellationRequested || !_clarifyWatch.ContainsKey(session)
                    || _entries.Any(e => e.SessionId == session && e.Kind == PromptKind.Clarify)) return;
                _clarifyWatch.Remove(session);
                _undelivered.Add(session);
                Changed(session);
            }
            Flush();
        });
    }

    // ------------------------------------------------------------------ approval.pending (rule 3)

    public void ReplayApprovals(string session)
    {
        if (session.Length == 0) return;
        int revision;
        JsonObject parameters;
        lock (_gate)
        {
            revision = _approvalsRevision.GetValueOrDefault(session);
            parameters = new JsonObject { ["session_id"] = session };
            if (_runtimes.GetValueOrDefault(session)?.Profile is { } profile) parameters["profile"] = profile;
        }
        _ = Task.Run(async () =>
        {
            JsonNode result;
            try { result = await _transport.CallAsync("approval.pending", parameters, TimeSpan.FromSeconds(30)); }
            catch (GatewayException) { return; }
            lock (_gate)
            {
                if (_shutDown || _approvalsRevision.GetValueOrDefault(session) != revision) return;
                ReconcileApprovals(session, (result.Arr("approvals") ?? []).OfType<JsonObject>().ToList());
            }
            Flush();
        });
    }

    private void ReconcileApprovals(string session, List<JsonObject> listed)
    {
        var requests = listed.Select(a => a.Str("request_id")).Where(r => r != null).ToHashSet();
        var absent = _entries.Where(e => e.SessionId == session && e.Kind == PromptKind.Approval && e.State == EntryState.Open
            && e.QueueRequestId != null && !requests.Contains(e.QueueRequestId)).ToList();
        // A report turn's approval lives in the messaging gateway's queue: ask open_requests before removing it.
        if (absent.Any(e => e.SrqOpen)) ProbeSoon(session);
        var gone = absent.Where(e => !e.SrqOpen).ToList();
        var any = gone.Count > 0;
        foreach (var e in gone) _entries.Remove(e);
        foreach (var approval in listed)
        {
            if (approval.Str("request_id") is not { Length: > 0 } request || _entries.Any(e => e.QueueRequestId == request)) continue;
            AddQueueOnly(session, approval);
            any = true;
        }
        foreach (var e in _entries.Where(e => e.SessionId == session && e.Kind == PromptKind.Approval
            && e.QueueRequestId != null && requests.Contains(e.QueueRequestId))) e.UnconfirmedSince = null;
        if (any)
        {
            BumpApprovals(session);
            Changed(session);
        }
    }

    private void BumpApprovals(string session)
    {
        _approvalsRevision[session] = _approvalsRevision.GetValueOrDefault(session) + 1;
        if (!_entries.Any(e => e.SessionId == session && e.Kind == PromptKind.Approval)) _stackSize[session] = 0;
    }

    // ------------------------------------------------------------------ answers (§3.4)

    private void NoteAnswered(string id, int? epoch = null)
    {
        PruneRecentlyAnswered();
        _recentlyAnswered.RemoveAll(a => a.Id == id);
        _recentlyAnswered.Add(new Answered { Id = id, At = Now(), Epoch = epoch });
        if (_recentlyAnswered.Count > 128) _recentlyAnswered.RemoveRange(0, _recentlyAnswered.Count - 128);
    }

    private void AnsweredOn(string id, int epoch)
    {
        lock (_gate)
            if (_recentlyAnswered.FirstOrDefault(a => a.Id == id) is { } a) a.Epoch = epoch;
    }

    private void ForgetAnswered(string id)
    {
        lock (_gate) _recentlyAnswered.RemoveAll(a => a.Id == id);
    }

    /// A re-delivery of an id this app answered. On the socket the answer went out on (or while it is in flight) it is
    /// a stale list built before Hermes read our frame, so it is ignored. On a later socket Hermes never saw the answer:
    /// the id is forgotten and the request counts as new (spec 1x §2.3).
    private bool AlreadyAnswered(string id, int deliveredOn)
    {
        PruneRecentlyAnswered();
        if (_recentlyAnswered.FirstOrDefault(a => a.Id == id) is not { } answered) return false;
        if (answered.Epoch is { } sentOn && deliveredOn > sentOn)
        {
            _recentlyAnswered.Remove(answered);
            return false;
        }
        return true;
    }

    private void PruneRecentlyAnswered()
    {
        var cutoff = Now() - _timing.RecentlyAnsweredTtl;
        _recentlyAnswered.RemoveAll(a => a.At < cutoff);
    }

    /// An automatic answer (a refusal, an empty clarify, a decline), fire and forget. A failed send forgets the id so
    /// its re-delivery is answered again. Called under the lock.
    private void SendResult(string id, JsonNode result)
    {
        NoteAnswered(id);
        _ = Task.Run(async () =>
        {
            try { AnsweredOn(id, await _transport.RespondAsync(id, result)); }
            catch (GatewayException) { ForgetAnswered(id); }
        });
    }

    private void SendError(string id, int code, string message)
    {
        NoteAnswered(id);
        _ = Task.Run(async () =>
        {
            try { AnsweredOn(id, await _transport.FailAsync(id, code, message)); }
            catch (GatewayException) { ForgetAnswered(id); }
        });
    }

    /// Hands one answer to the socket, exactly once: the id is marked answered first (a re-delivery or a second tap
    /// can't send again) and taken back if the send failed.
    private async Task RespondOnceAsync(string id, JsonNode result, string offline, string failed)
    {
        lock (_gate) NoteAnswered(id);
        try { AnsweredOn(id, await _transport.RespondAsync(id, result)); }
        catch (GatewayException e)
        {
            ForgetAnswered(id);
            if (e.Code == "offline" || !_transport.Connected) throw new PromptAnswerException(offline, true);
            throw new PromptAnswerException(failed, false);
        }
    }

    /// [authority] A shared question's answer: clarify.respond names the prompt and its turn; "" is a skip.
    private async Task SharedRespondAsync(string id, string session, SharedPrompt prompt, string answer)
    {
        JsonObject parameters;
        lock (_gate)
        {
            parameters = new JsonObject
            {
                ["session_id"] = session, ["prompt_id"] = prompt.PromptId, ["execution_generation"] = prompt.Generation,
                ["answer"] = answer,
            };
            if (_runtimes.GetValueOrDefault(session)?.Profile is { } profile) parameters["profile"] = profile;
            NoteAnswered(id);
        }
        try { await _transport.CallAsync("clarify.respond", parameters, _timing.LockTimeout); }
        catch (GatewayException e)
        {
            ForgetAnswered(id);
            throw new PromptAnswerException(IsOffline(e) ? Offline : ClarifyFailed, IsOffline(e));
        }
    }

    private bool IsOffline(GatewayException e) => e.Code == "offline" || !_transport.Connected;

    /// Run, Reject, Allow for This Chat, Always Allow. Throws PromptAnswerException (the card opens again).
    public async Task AnswerApprovalAsync(string id, ApprovalChoice choice)
    {
        Entry entry;
        lock (_gate)
        {
            if (_entries.FirstOrDefault(e => e.Id == id) is not { Kind: PromptKind.Approval, State: EntryState.Open } e) return;
            entry = e;
            e.State = EntryState.Answering;
            e.Answering = choice;
            Changed(e.SessionId);
        }
        Flush();
        try
        {
            if (entry.SrqOpen)
                await RespondOnceAsync(id, new JsonObject { ["choice"] = choice.Wire() }, ApprovalOffline, ApprovalFailed);
            else await ApprovalRespondAsync(entry, choice);
        }
        catch (PromptAnswerException)
        {
            lock (_gate)
            {
                if (_entries.FirstOrDefault(e => e.Id == id) is { } back)
                {
                    back.State = EntryState.Open;
                    back.Answering = null;
                    Changed(entry.SessionId);
                }
            }
            Flush();
            throw;
        }
        lock (_gate)
            if (entry.QueueRequestId is { } request) NoteAnswered($"queue:{request}");
        Leave(id, entry.SessionId);
        ReplayApprovals(entry.SessionId);
    }

    /// A request the app holds, as an alert reads it (NotificationHub.observeRequest's entry): null once it went.
    public HeldRequest? Held(string id)
    {
        lock (_gate)
        {
            if (_entries.FirstOrDefault(e => e.Id == id) is not { } e) return null;
            var runtime = _runtimes.GetValueOrDefault(e.SessionId);
            return new HeldRequest(e.Id, e.Kind, e.SessionId, (JsonObject)e.Params.DeepClone(), runtime?.Profile, runtime?.StoredId);
        }
    }

    /// Approve Once / Deny on a local alert (ServerRequests.swift answerApprovalFromAlert, UX study #256): on a cold
    /// launch the request isn't here until the socket is up and the chat's approvals are replayed, so this waits for it
    /// to be open, up to `within` (the Mac's 6 s); one that never shows, or was answered here already, is Gone, said,
    /// never dropped in silence. An open one is answered through AnswerApprovalAsync, the card's own call, and throws
    /// as that does.
    public async Task<AlertAnswer> AnswerApprovalFromAlertAsync(string id, ApprovalChoice choice, TimeSpan? within = null)
    {
        var deadline = DateTime.UtcNow + (within ?? TimeSpan.FromSeconds(6));
        while (true)
        {
            bool open;
            lock (_gate)
            {
                if (_recentlyAnswered.Any(a => a.Id == id)) return AlertAnswer.Gone;
                open = _entries.Any(e => e.Id == id && e.Kind == PromptKind.Approval && e.State == EntryState.Open);
            }
            if (open)
            {
                await AnswerApprovalAsync(id, choice);
                return AlertAnswer.Sent;
            }
            if (DateTime.UtcNow >= deadline) return AlertAnswer.Gone;
            await Task.Delay(200);
        }
    }

    /// A queue-backed approval with no srq: approval.respond (330 s, retried once on a timeout only).
    private async Task ApprovalRespondAsync(Entry entry, ApprovalChoice choice)
    {
        if (!_transport.Connected) throw new PromptAnswerException(ApprovalOffline, true);
        var parameters = new JsonObject { ["session_id"] = entry.SessionId, ["choice"] = choice.Wire(), ["all"] = false };
        lock (_gate)
        {
            if (entry.QueueRequestId is { } request) parameters["request_id"] = request;
            if (_runtimes.GetValueOrDefault(entry.SessionId)?.Profile is { } profile) parameters["profile"] = profile;
            NoteAnswered(entry.Id);
        }
        for (var attempt = 1; ; attempt++)
        {
            try
            {
                await _transport.CallAsync("approval.respond", parameters, _timing.ApprovalRespondTimeout);
                return;
            }
            catch (GatewayException e) when (e.Code == "timeout" && attempt == 1) { }
            catch (GatewayException e)
            {
                ForgetAnswered(entry.Id);
                throw new PromptAnswerException(IsOffline(e) ? ApprovalOffline : ApprovalFailed, IsOffline(e));
            }
        }
    }

    /// The expired card's Dismiss: it goes at once; the gateway is told no, best effort.
    public void DismissExpiredApproval(string id)
    {
        lock (_gate)
        {
            var i = _entries.FindIndex(e => e.Id == id);
            if (i < 0) return;
            var entry = _entries[i];
            _entries.RemoveAt(i);
            if (entry.QueueRequestId is { } request) NoteAnswered($"queue:{request}");
            BumpApprovals(entry.SessionId);
            Changed(entry.SessionId);
            if (entry.SrqOpen) SendResult(id, new JsonObject { ["choice"] = "deny" });
            else
            {
                NoteAnswered(id);
                var parameters = new JsonObject { ["session_id"] = entry.SessionId, ["choice"] = "deny", ["all"] = false };
                if (entry.QueueRequestId is { } r) parameters["request_id"] = r;
                if (_runtimes.GetValueOrDefault(entry.SessionId)?.Profile is { } profile) parameters["profile"] = profile;
                _ = Task.Run(async () =>
                {
                    try { await _transport.CallAsync("approval.respond", parameters, TimeSpan.FromSeconds(30)); }
                    catch (GatewayException) { }
                });
            }
        }
        Flush();
    }

    /// The card fades out, then goes (§4.2).
    private void Leave(string id, string session)
    {
        lock (_gate)
        {
            if (_entries.FirstOrDefault(e => e.Id == id) is not { } e) return;
            e.State = EntryState.Leaving;
            Changed(session);
        }
        Flush();
        _ = After(_timing.Leaving, _life.Token, () =>
        {
            lock (_gate)
            {
                var j = _entries.FindIndex(e => e.Id == id);
                if (j < 0) return;
                _entries.RemoveAt(j);
                BumpApprovals(session);
                Changed(session);
            }
            Flush();
        });
    }

    /// Dock Send: one clarify.lock per question, in order, the nulls too — the last lock resolves the wait.
    public async Task SendClarifyAsync(string requestId, IReadOnlyList<(string Qid, string? Answer)> answers)
    {
        Entry entry;
        string? profile;
        lock (_gate)
        {
            if (_entries.FirstOrDefault(e => e.Id == requestId) is not { Kind: PromptKind.Clarify, State: EntryState.Open } e) return;
            if (!_transport.Connected) throw new PromptAnswerException(Offline, true);
            entry = e;
            e.State = EntryState.Answering;
            profile = _runtimes.GetValueOrDefault(e.SessionId)?.Profile;
            Changed(e.SessionId);
        }
        Flush();
        try
        {
            if (entry.Prompt is { } prompt)
            {
                var answer = answers.FirstOrDefault(a => a.Qid == prompt.PromptId).Answer;
                await SharedRespondAsync(requestId, entry.SessionId, prompt, answer ?? "");
            }
            else
            {
                foreach (var (qid, answer) in answers)
                {
                    var parameters = new JsonObject
                    {
                        ["request_id"] = requestId, ["question_id"] = qid, ["answer"] = answer,
                    };
                    if (profile != null) parameters["profile"] = profile;
                    var result = await _transport.CallAsync("clarify.lock", parameters, _timing.LockTimeout);
                    if (result.Str("status") == "expired") break; // the wait already ended: done (web parity)
                }
            }
        }
        catch (Exception x) when (x is GatewayException or PromptAnswerException)
        {
            lock (_gate)
            {
                if (_entries.FirstOrDefault(e => e.Id == requestId) is { } back)
                {
                    back.State = EntryState.Open;
                    Changed(entry.SessionId);
                }
            }
            Flush();
            if (x is PromptAnswerException) throw;
            var offline = IsOffline((GatewayException)x);
            throw new PromptAnswerException(offline ? Offline : ClarifyFailed, offline);
        }
        IReadOnlyList<SentClarifyRow> rows;
        lock (_gate)
            rows = ClarifyStaging.SentRows(ClarifyText.Normalize(entry.Params.Get("questions")),
                _drafts.GetValueOrDefault(requestId)?.Stages ?? new Dictionary<string, ClarifyStage>());
        FinishClarify(entry, rows);
    }

    /// Dock Skip: a response without answers is the gateway's cancel-all.
    public async Task SkipClarifyAsync(string requestId)
    {
        Entry entry;
        lock (_gate)
        {
            if (_entries.FirstOrDefault(e => e.Id == requestId) is not { Kind: PromptKind.Clarify, State: EntryState.Open } e) return;
            entry = e;
            e.State = EntryState.Answering;
            Changed(e.SessionId);
        }
        Flush();
        try
        {
            if (entry.Prompt is { } prompt) await SharedRespondAsync(requestId, entry.SessionId, prompt, "");
            else await RespondOnceAsync(requestId, new JsonObject(), Offline, ClarifyFailed);
        }
        catch (PromptAnswerException)
        {
            lock (_gate)
            {
                if (_entries.FirstOrDefault(e => e.Id == requestId) is { } back)
                {
                    back.State = EntryState.Open;
                    Changed(entry.SessionId);
                }
            }
            Flush();
            throw;
        }
        FinishClarify(entry, ClarifyStaging.SentRows(ClarifyText.Normalize(entry.Params.Get("questions")),
            new Dictionary<string, ClarifyStage>(), skipped: true));
    }

    private void FinishClarify(Entry entry, IReadOnlyList<SentClarifyRow> rows)
    {
        lock (_gate)
        {
            if (!_recentlyAnswered.Any(a => a.Id == entry.Id)) NoteAnswered(entry.Id);
            _entries.RemoveAll(e => e.Id == entry.Id);
            _drafts.Remove(entry.Id);
            _sent[entry.SessionId] = new SentClarify(entry.Id, rows);
            Changed(entry.SessionId);
        }
        Flush();
    }

    /// A sheet's primary, or its red decline (""). Throws PromptAnswerException (the sheet opens again with its text).
    public async Task AnswerValueAsync(string requestId, string value)
    {
        Entry entry;
        lock (_gate)
        {
            if (_entries.FirstOrDefault(e => e.Id == requestId) is not { State: EntryState.Open } e || !e.Kind.IsValuePrompt()) return;
            entry = e;
            e.State = EntryState.Answering;
            Changed(e.SessionId);
        }
        Flush();
        try { await RespondOnceAsync(requestId, new JsonObject { ["value"] = value }, Offline, ValueFailed(entry.Kind)); }
        catch (PromptAnswerException)
        {
            lock (_gate)
            {
                if (_entries.FirstOrDefault(e => e.Id == requestId) is { } back)
                {
                    back.State = EntryState.Open;
                    Changed(entry.SessionId);
                }
            }
            Flush();
            throw;
        }
        lock (_gate)
        {
            _entries.RemoveAll(e => e.Id == requestId);
            Changed(entry.SessionId);
        }
        Flush();
    }

    // ------------------------------------------------------------------ approval timeout (§4.2 expiry)

    /// `approvals.timeout` of `profile` from GET /api/config, cached 5 min per profile; 300 when unset.
    public async Task<TimeSpan> ApprovalTimeoutAsync(string? profile, bool fresh)
    {
        var key = profile ?? "";
        lock (_gate)
            if (!fresh && _timeouts.TryGetValue(key, out var cached) && Now() - cached.At < _timing.TimeoutCacheTtl)
                return cached.Value;
        var config = await _transport.ConfigAsync(profile);
        lock (_gate)
        {
            if (config == null) return _timeouts.TryGetValue(key, out var old) ? old.Value : ApprovalExpiry.DefaultTimeout;
            var value = ApprovalExpiry.Timeout(config);
            _timeouts[key] = (value, Now());
            return value;
        }
    }

    // ------------------------------------------------------------------ fan-out

    private void Changed(string session) => _dirty.Add(session);

    /// Tells chats, the Bots rows and the sheet store what changed. Always called with the lock released.
    private void Flush()
    {
        List<ChatQuestions> links;
        var needs = new List<(string, string, string?, NeedsInput?)>();
        List<(string, PromptKind, string, string?)> arrived;
        List<string> timedOut;
        HashSet<string>? gone = null;
        lock (_gate)
        {
            if (_dirty.Count == 0 && _arrived.Count == 0 && _timedOut.Count == 0) return;
            var sessions = _dirty.ToList();
            _dirty.Clear();
            links = _links.Where(l => sessions.Any(l.Covers)).ToList();
            foreach (var session in sessions)
            {
                if (!_runtimes.TryGetValue(session, out var runtime)) continue;
                var kind = PromptsLocked([session]).NeedsInput;
                var told = _toldNeeds.TryGetValue(session, out var t) ? t : ((NeedsInput, string?)?)null;
                if (told?.Item1 != kind || (kind != null && told?.Item2 != runtime.StoredId))
                {
                    if (kind is { } k) _toldNeeds[session] = (k, runtime.StoredId);
                    else _toldNeeds.Remove(session);
                    needs.Add((session, runtime.Profile, runtime.StoredId, kind));
                }
            }
            var ids = _entries.Select(e => e.Id).ToHashSet();
            if (!ids.SetEquals(_knownIds))
            {
                gone = _knownIds.Except(ids).ToHashSet();
                _knownIds = ids;
            }
            arrived = [.. _arrived];
            _arrived.Clear();
            timedOut = [.. _timedOut];
            _timedOut.Clear();
        }
        foreach (var link in links) link.RaiseChanged();
        foreach (var (s, p, st, k) in needs) NeedsInputChanged?.Invoke(s, p, st, k);
        if (gone is { Count: > 0 }) Removed?.Invoke(gone);
        foreach (var (id, kind, s, p) in arrived) Arrived?.Invoke(id, kind, s, p);
        foreach (var s in timedOut) ApprovalTimedOut?.Invoke(s);
    }

    private static async Task After(TimeSpan wait, CancellationToken ct, Func<Task> action)
    {
        try { if (wait > TimeSpan.Zero) await Task.Delay(wait, ct); }
        catch (OperationCanceledException) { return; }
        if (ct.IsCancellationRequested) return;
        try { await action(); } catch (GatewayException) { }
    }

    private static Task After(TimeSpan wait, CancellationToken ct, Action action) =>
        After(wait, ct, () => { action(); return Task.CompletedTask; });

    /// Sign-out / account switch (rule 9): everything goes, drafts included.
    public void Dispose()
    {
        lock (_gate)
        {
            if (_shutDown) return;
            _shutDown = true;
            _life.Cancel();
            var sessions = _entries.Select(e => e.SessionId).Concat(_sent.Keys).Concat(_undelivered).Distinct().ToList();
            _entries.Clear();
            _drafts.Clear();
            _sent.Clear();
            _undelivered.Clear();
            _recentlyAnswered.Clear();
            foreach (var s in sessions) Changed(s);
        }
        Flush();
        lock (_gate)
        {
            _links.Clear();
            _runtimes.Clear();
            _runtimeOrder.Clear();
        }
    }
}

/// A chat's tie to the centre (HermesKit `PromptChatLink` + LiveChatSession+Prompts.swift's `ChatPrompting`): its
/// runtime id, whether it is on screen, and the answers it gives. Changed fires on a background thread.
public sealed class ChatQuestions : IDisposable
{
    private readonly QuestionCenter _center;
    private string[] _sessionIds = [];

    public string Profile { get; }
    public IReadOnlyList<string> SessionIds => _sessionIds;
    /// The chat is on screen: session.info replays the approval queue for it (rule 3).
    public bool Observing { get; set; } = true;
    /// The user stopped the turn and its end hasn't arrived: new requests for it are refused (§2.3).
    public Func<bool>? InterruptedProbe { get; set; }
    public bool TurnInterrupted => InterruptedProbe?.Invoke() ?? false;

    public event Action? Changed;

    internal ChatQuestions(QuestionCenter center, string profile)
    {
        _center = center;
        Profile = profile;
    }

    public bool Covers(string session) => Array.IndexOf(_sessionIds, session) >= 0;

    /// The chat bound (or re-bound) its runtime id. While it is on screen the approval queue is read at once.
    public void Bind(string runtime, string? storedId)
    {
        var previous = _sessionIds.FirstOrDefault();
        if (previous == runtime)
        {
            _center.Bound(runtime, runtime, Profile, storedId);
            return;
        }
        _sessionIds = [runtime];
        _center.Bound(runtime, previous, Profile, storedId);
        if (Observing) _center.ReplayApprovals(runtime);
    }

    public ChatPrompts Prompts => _sessionIds.Length == 0 ? ChatPrompts.None : _center.PromptsFor(_sessionIds);
    public bool Connected => _center.Connected;

    public Task AnswerApprovalAsync(string id, ApprovalChoice choice) => _center.AnswerApprovalAsync(id, choice);
    public void DismissExpiredApproval(string id) => _center.DismissExpiredApproval(id);
    public Task<TimeSpan> ApprovalTimeoutAsync(bool fresh) => _center.ApprovalTimeoutAsync(Profile, fresh);
    public ClarifyDraft? ClarifyDraft(string requestId) => _center.Draft(requestId);
    public void SaveClarifyDraft(string requestId, ClarifyDraft draft) => _center.SaveDraft(requestId, draft);
    public Task SendClarifyAsync(string requestId, IReadOnlyList<(string Qid, string? Answer)> answers) =>
        _center.SendClarifyAsync(requestId, answers);
    public Task SkipClarifyAsync(string requestId) => _center.SkipClarifyAsync(requestId);
    /// "" declines.
    public Task AnswerValueAsync(string requestId, string value) => _center.AnswerValueAsync(requestId, value);
    public void ReconnectNow() => _center.ReconnectNow();

    /// The chat came on screen: confirm what is still open (probe) and read the approval queue (§3.5).
    public void CameOnScreen()
    {
        if (_sessionIds.FirstOrDefault() is not { } runtime) return;
        var prompts = Prompts;
        if (prompts.Clarify != null || prompts.Values.Count > 0 || prompts.Approvals.Any(a => a.Id.StartsWith("srq-")))
            _center.ProbeSoon(runtime);
        _center.ReplayApprovals(runtime);
    }

    internal void RaiseChanged() => Changed?.Invoke();

    public void Dispose() => _center.Unlink(this);
}
