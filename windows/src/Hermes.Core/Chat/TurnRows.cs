// [WIN-OWN-TURN-ROWS] Our own running turns on the Bots/Sessions rows, kept after the chat leaves the screen until the
// turn ends, as the Mac's AppModel at 93f984bb1 (App/AppModel.swift):
//   - `runningChats` (runtime id → bot and stored id) and `turnWorking` (HermesKit/Activity/TurnWorking.swift): here
//     `_running` and ChatsWorking;
//   - `onRunningChange`: setWorking(running || chat.externalWorking), and when it ended with no other turn on, the
//     gateway's last word no longer counts (`liveStatus.turnEnded`): Running;
//   - `onExternalWorkChange`: setWorking(working || chat.reportsRunning): External;
//   - `onStoredIdResolved` (TurnWorking.resolved): Resolved; `onRuntimeBound`: Bound;
//   - `gatewayEvent` → `offScreenTurnEnded` (message.complete, error, session.info running:false of a chat not on
//     screen): Event, heard through Listen on the client's socket; a message.complete's reply rides the change
//     (OffScreenReply) and ApplyTo gives it to the rows (`botStore.noteChatActivity(…unseen: true, said: false)`,
//     `sessionStore.noteLatest(…role: "assistant")`) [WIN-OFFSCREEN-TURN-END];
//   - `noteTurnOutcome` (a message.complete or error of the chat on screen, or of a turn of ours off screen): its bot's
//     standing problem (BotStore.NoteTurnFailed/NoteTurnSucceeded), Outcomes; `liveSteps.clear(runtime)`: the step the
//     ended turn was on goes from its bot's row, StepEnds [WIN-OFFSCREEN-END-REST];
//   - the account teardown (`turnWorking = TurnWorking()`, `runningChats = [:]`, `liveSteps.reset()`): UseSocket, at
//     the moment the app signs out or moves to another gateway (AppState.ClientChanged) [WIN-OFFSCREEN-END-REST];
//   - [WIN-LIVE-STEPS] `liveSteps.handle(event, roster:)` on every frame of the client's socket, `liveSteps.clear` at an
//     off-screen end, `liveSteps.reset()` at the teardown, and `pushSteps` (each step by its chat's bot and stored id:
//     a running chat of ours, else a chat on screen): Steps, PushSteps;
//   - `reattachUnheardTurns`: Windows can't re-bind a turn no chat hears (no `session.activate` here), so a reconnect
//     drops those marks and the gateway's live registry (session.active_list) says whether they still run: Reconnected.
// On the Mac the LiveChatSession lives on after its screen closes and keeps reporting; on Windows the chat is disposed
// with its page (ChatViewModel.DisposeAsync), so Follow's Dispose is the screen leaving (Closed) and the turn's end
// comes from the socket. The app (Features/Bots/ChatRowsWorking) applies each change to the stores (ApplyTo).

using Hermes.Core.Activity;
using Hermes.Core.Bots;
using Hermes.Core.Groups;
using Hermes.Core.Rpc;
using Hermes.Core.Sessions;

namespace Hermes.Core.Chat;

/// [WIN-OFFSCREEN-TURN-END] A reply that landed while its chat was off screen (`offScreenTurnEnded`'s `reply`): the
/// bot it belongs to, the chat's stored id (null when it never came back), and the reply's words.
public readonly record struct OffScreenReply(string Profile, string? StoredId, string Text);

/// [WIN-OFFSCREEN-END-REST] How a turn in a bot's chat ended (`noteTurnOutcome`): failed, with the error's words and the
/// gateway's reason, or answered.
public readonly record struct TurnOutcome(string Profile, bool Failed, string? Message = null, string? Reason = null);

/// [WIN-OFFSCREEN-END-REST] A turn ended off screen: the step its chat was on goes from its bot's row.
public readonly record struct StepEnd(string Profile, string? StoredId);

/// What a hook changed: the bots whose rows draw again (with the Sessions rows), the stored ids whose turn of ours
/// ended (the gateway's stale "working" for them is dropped: LiveStatus.TurnEnded), the replies that landed off
/// screen (their rows show them and get their dot), and whether a chat's live step changed ([WIN-LIVE-STEPS]: the rows
/// take the steps again, PushSteps).
public readonly record struct TurnRowsChange(IReadOnlyList<string> Profiles, IReadOnlyList<string> Ended,
    IReadOnlyList<OffScreenReply>? Replies = null, IReadOnlyList<TurnOutcome>? Outcomes = null,
    IReadOnlyList<StepEnd>? StepEnds = null, bool Steps = false)
{
    public static TurnRowsChange None => new([], []);
    public bool IsEmpty => !Steps && OnlySteps;
    /// Nothing changed but a live step (the app hands those over once per quarter second).
    public bool OnlySteps => (Profiles?.Count ?? 0) == 0 && (Ended?.Count ?? 0) == 0 && (Replies?.Count ?? 0) == 0
        && (Outcomes?.Count ?? 0) == 0 && (StepEnds?.Count ?? 0) == 0;
}

public sealed class TurnRows
{
    private readonly object _gate = new();
    /// Runtime id → the chat whose turn of ours runs by it (`runningChats`).
    private readonly Dictionary<string, (string Profile, string? StoredId)> _running = [];
    /// Runtime ids of the chats on screen now: they report their own end (`the open chat reports itself`).
    private readonly HashSet<ChatSession> _onScreen = [];

    /// The chats working, by bot and stored id (`turnWorking`, `runningSessions`).
    public ChatsWorking Working { get; } = new();

    /// [WIN-LIVE-STEPS] Each heard chat's newest step (`liveSteps`), by runtime id. Guarded by `_gate`.
    private readonly LiveSteps _steps = new();

    /// The roster a `message_agent` step names its bot by (`DeliveryRoster.seats`).
    public Func<IReadOnlyList<DeliveryMessages.Seat>> Roster { get; set; } = () => DeliveryRoster.Seats;

    /// Each heard chat's step words by runtime id (tests).
    public IReadOnlyDictionary<string, string> StepsByRuntime { get { lock (_gate) return new Dictionary<string, string>(_steps.ByRuntime); } }

    /// Raised on the calling thread after each hook that changed something.
    public event Action<TurnRowsChange>? Changed;

    /// A turn of ours runs by this runtime id (tests).
    public bool Tracks(string runtimeId) { lock (_gate) return _running.ContainsKey(runtimeId); }

    private static string? Id(string? storedId) => string.IsNullOrEmpty(storedId) ? null : storedId;

    private TurnRowsChange Done(string? profile, bool changed, string? ended = null, OffScreenReply? reply = null,
        TurnOutcome? outcome = null, StepEnd? step = null, bool steps = false)
    {
        var c = new TurnRowsChange(changed && profile != null ? [profile] : [], ended != null ? [ended] : [],
            reply is { } r ? [r] : null, outcome is { } o ? [o] : null, step is { } st ? [st] : null, steps);
        if (!c.IsEmpty) Changed?.Invoke(c);
        return c;
    }

    /// `onRunningChange`: a turn of ours started or ended in a chat on screen.
    public TurnRowsChange Running(string profile, string? storedId, string? runtimeId, bool running, bool external)
    {
        var id = Id(storedId);
        lock (_gate)
        {
            if (runtimeId != null)
            {
                if (running)
                {
                    // A turn still running is tracked under the id it runs by now, whatever id it started under.
                    foreach (var key in _running.Where(kv => kv.Key != runtimeId && kv.Value.Profile == profile && kv.Value.StoredId == id)
                                 .Select(kv => kv.Key).ToList())
                        _running.Remove(key);
                    _running[runtimeId] = (profile, id);
                }
                else _running.Remove(runtimeId);
            }
            else if (!running && id != null)
            {
                // Reclaimed mid-turn: the runtime id went before the turn said it ended; the entry goes by its chat.
                foreach (var key in _running.Where(kv => kv.Value.Profile == profile && kv.Value.StoredId == id).Select(kv => kv.Key).ToList())
                    _running.Remove(key);
            }
        }
        var changed = Working.Set(profile, id, running || external);
        return Done(profile, changed, !running && !external ? id : null);
    }

    /// `onExternalWorkChange`: another Hermes process's turn in a chat on screen began or ended (or the screen left).
    public TurnRowsChange External(string profile, string? storedId, bool working, bool ownRunning) =>
        Done(profile, Working.Set(profile, Id(storedId), working || ownRunning));

    /// `onStoredIdResolved`: the chat's stored id came back (or the resume named another): its mark moves there, and an
    /// off-screen end of its turn names the new id.
    public TurnRowsChange Resolved(string profile, string? runtimeId, string? from, string to)
    {
        var old = Id(from);
        lock (_gate)
        {
            if (runtimeId != null && _running.TryGetValue(runtimeId, out var tracked) && tracked.StoredId == old)
                _running[runtimeId] = (tracked.Profile, to);
        }
        return Done(profile, Working.Move(profile, old, to));
    }

    /// `onRuntimeBound`: a running turn's chat bound (or re-bound) its runtime id: its end, heard off screen, comes by
    /// the new one.
    public void Bound(string profile, string? storedId, string? old, string now, bool running)
    {
        if (!running) return;
        lock (_gate)
        {
            if (old != null && old != now) _running.Remove(old);
            _running[now] = (profile, Id(storedId));
        }
    }

    /// The chat left the screen: another process's turn stops showing with its watch; a turn of ours stays until its
    /// end arrives on the socket, unless there is no runtime id to hear it by.
    public TurnRowsChange Closed(string profile, string? storedId, string? runtimeId, bool running)
    {
        var id = Id(storedId);
        bool keep;
        lock (_gate)
        {
            keep = running && runtimeId != null;
            if (keep) _running[runtimeId!] = (profile, id);
            else if (runtimeId != null) _running.Remove(runtimeId);
        }
        return Done(profile, Working.Set(profile, id, keep));
    }

    /// `gatewayEvent`: a turn of ours running off screen ended (`offScreenTurnEnded`). The chat on screen reports its own
    /// end; only its bot's standing problem comes from here (`noteTurnOutcome`), when the caller names its bot
    /// (`screenProfile`).
    public TurnRowsChange Event(RpcEvent e, bool onScreen, string? screenProfile = null)
    {
        if (e.SessionId.Length == 0) return TurnRowsChange.None;
        // [WIN-LIVE-STEPS] `liveSteps.handle(event, roster:)`: every frame of a chat this run hears, on screen or not.
        var roster = Roster();
        bool stepped;
        lock (_gate) stepped = _steps.Handle(e, roster);
        var finished = e.Type is "message.complete" or "error";
        if (onScreen)
            return finished && screenProfile != null && Outcome(e, screenProfile) is { } shown ? Done(null, false, outcome: shown, steps: stepped)
                : Done(null, false, steps: stepped);
        var ended = e.Type switch
        {
            "message.complete" or "error" => true,
            "session.info" => e.Payload?["running"] is { } r && r.GetValueKind() == System.Text.Json.JsonValueKind.False,
            _ => false,
        };
        if (!ended) return Done(null, false, steps: stepped);
        (string Profile, string? StoredId) tracked;
        lock (_gate)
        {
            if (!_running.Remove(e.SessionId, out tracked)) return Done(null, false, steps: stepped);
            stepped |= _steps.Clear(e.SessionId);                            // `offScreenTurnEnded`: liveSteps.clear(runtime)
        }
        // The reply landed while its chat was off screen: the rows say so (and the bot gets its dot). Only a
        // message.complete's `text` (a string) is a reply; an error or a session.info end has none.
        var text = e.Type == "message.complete" && e.Payload?["text"] is System.Text.Json.Nodes.JsonValue v
            && v.GetValueKind() == System.Text.Json.JsonValueKind.String ? v.GetValue<string>() : null;
        return Done(tracked.Profile, Working.Set(tracked.Profile, tracked.StoredId, false), tracked.StoredId,
            text != null ? new OffScreenReply(tracked.Profile, tracked.StoredId, text) : null,
            finished ? Outcome(e, tracked.Profile) : null, new StepEnd(tracked.Profile, tracked.StoredId), stepped);
    }

    /// [botslist] `noteTurnOutcome`: an error (the frame, a `status: "error"`, or a truthy `error`) is a failure with
    /// the first words it has (`message`, `error`, `text`) and the gateway's reason (`data.reason`, `reason`); any other
    /// end that isn't partial is a good turn.
    public static TurnOutcome? Outcome(RpcEvent e, string profile)
    {
        var payload = e.Payload as System.Text.Json.Nodes.JsonObject ?? [];
        static string? Str(System.Text.Json.Nodes.JsonNode? n) =>
            n is System.Text.Json.Nodes.JsonValue v && v.GetValueKind() == System.Text.Json.JsonValueKind.String ? v.GetValue<string>() : null;
        static string? NonEmpty(System.Text.Json.Nodes.JsonNode? n) => Str(n) is { } t && t.Trim().Length > 0 ? t : null;
        if (e.Type == "error" || Str(payload["status"]) == "error" || Activity.ActivityJson.IsTruthy(payload["error"]))
        {
            var message = NonEmpty(payload["message"]) ?? NonEmpty(payload["error"]) ?? Str(payload["text"]);
            var reason = Str(payload["data"]?["reason"]) ?? Str(payload["reason"]);
            return new TurnOutcome(profile, true, message, reason);
        }
        var partial = payload["partial"] is System.Text.Json.Nodes.JsonValue p && p.GetValueKind() == System.Text.Json.JsonValueKind.True;
        return partial ? null : new TurnOutcome(profile, false);
    }

    /// The link came back: turns no chat on screen hears may have ended in the gap with nobody told. Their marks go;
    /// the gateway's live registry says whether they still run.
    public TurnRowsChange Reconnected(IReadOnlySet<string> heard)
    {
        List<(string Profile, string? StoredId)> dropped;
        var stepped = false;
        lock (_gate)
        {
            var keys = _running.Keys.Where(k => !heard.Contains(k)).ToList();
            dropped = [.. keys.Select(k => _running[k])];
            foreach (var k in keys) { _running.Remove(k); stepped |= _steps.Clear(k); }
        }
        var profiles = new List<string>();
        foreach (var (profile, id) in dropped)
            if (Working.Set(profile, id, false) && !profiles.Contains(profile)) profiles.Add(profile);
        // As far as this device knows their turns are over: the steps they were on go too.
        var c = new TurnRowsChange(profiles, [], StepEnds: [.. dropped.Select(d => new StepEnd(d.Profile, d.StoredId))], Steps: stepped);
        if (!c.IsEmpty) Changed?.Invoke(c);
        return c;
    }

    /// The account went (sign-out, or a sign-in to another gateway): no mark of its turns outlives it, as the Mac's
    /// account teardown (93f984bb1 App/AppModel.swift: `turnWorking = TurnWorking()`, `runningChats = [:]`). Without it a
    /// turn closed off screen on the old gateway, whose end the new socket never carries, kept its bot's row Working… on
    /// the next account's bot of the same name (CI 45141338140, shots 218-222). The bots named had marks.
    public TurnRowsChange Reset()
    {
        List<string> profiles;
        bool stepped;
        lock (_gate)
        {
            _running.Clear();
            _onScreen.Clear();
            profiles = Working.Clear();
            stepped = _steps.ByRuntime.Count > 0;
            _steps.Reset();                                                  // `liveSteps.reset()`
        }
        var c = new TurnRowsChange(profiles, [], Steps: stepped);
        if (!c.IsEmpty) Changed?.Invoke(c);
        return c;
    }

    private RpcConnection? _socket;

    /// [WIN-OFFSCREEN-END-REST] One client's socket at a time. Another one (a sign-in to another gateway) or none (a
    /// sign-out, an ended session) is the account's teardown, at that moment: the old socket is no longer heard and the
    /// marks reset (Reset). The first socket heard resets nothing.
    public TurnRowsChange UseSocket(RpcConnection? rpc)
    {
        RpcConnection? was;
        lock (_gate)
        {
            if (ReferenceEquals(rpc, _socket)) return TurnRowsChange.None;
            was = _socket;
            _socket = rpc;
        }
        var c = TurnRowsChange.None;
        if (was != null)
        {
            Unlisten(was);
            c = Reset();
        }
        if (rpc != null) Listen(rpc);
        return c;
    }

    // MARK: the wiring (a chat on screen, the client's socket)

    /// A chat came on screen: its running state, another process's turn in it, its stored id and runtime id feed the
    /// rows. Dispose when it leaves the screen.
    public IDisposable Follow(ChatSession chat)
    {
        var runtime = chat.RuntimeId;
        var gate = new object();
        // A chat still on screen when its account went (UseSocket, Reset) no longer marks anything: what it says after
        // is about the old account's turn.
        bool Followed() { lock (_gate) return _onScreen.Contains(chat); }
        void OnRunning(bool running) { if (Followed()) Running(chat.Profile, chat.StoredId, chat.RuntimeId, running, chat.ExternalWorking); }
        void OnExternal(bool working) { if (Followed()) External(chat.Profile, chat.StoredId, working, chat.Busy); }
        void OnResolved(string from, string to) { if (Followed()) Resolved(chat.Profile, chat.RuntimeId, from, to); }
        void OnBound(string now)
        {
            if (!Followed()) return;
            string? old;
            lock (gate) { old = runtime; runtime = now; }
            Bound(chat.Profile, chat.StoredId, old, now, chat.Busy);
        }
        lock (_gate) _onScreen.Add(chat);
        chat.RunningChanged += OnRunning;
        chat.ExternalWorkChanged += OnExternal;
        chat.StoredIdResolved += OnResolved;
        chat.RuntimeBound += OnBound;
        if (chat.Busy) OnRunning(true);
        return new Leave(() =>
        {
            chat.RunningChanged -= OnRunning;
            chat.ExternalWorkChanged -= OnExternal;
            chat.StoredIdResolved -= OnResolved;
            chat.RuntimeBound -= OnBound;
            bool followed;
            lock (_gate) followed = _onScreen.Remove(chat);
            // Its leaving after the account's teardown keeps no mark for it (the Mac's chats go with `tearDown`).
            if (followed) Closed(chat.Profile, chat.StoredId, chat.RuntimeId, chat.Busy);
        });
    }

    /// The chat on screen that runs by this runtime id, if any.
    private ChatSession? OnScreen(string runtimeId)
    {
        lock (_gate) return _onScreen.FirstOrDefault(c => c.RuntimeId == runtimeId);
    }

    private HashSet<string> Heard()
    {
        lock (_gate) return _onScreen.Select(c => c.RuntimeId).OfType<string>().ToHashSet();
    }

    private void OnSocketEvent(RpcEvent e)
    {
        var shown = e.SessionId.Length == 0 ? null : OnScreen(e.SessionId);
        Event(e, shown != null, shown?.Profile);
    }
    private void OnSocketReconnected(bool _) => Reconnected(Heard());

    /// Hears the ends of turns whose chat left the screen, on the client's socket.
    public void Listen(RpcConnection rpc)
    {
        rpc.Event += OnSocketEvent;
        rpc.Reconnected += OnSocketReconnected;
    }

    public void Unlisten(RpcConnection rpc)
    {
        rpc.Event -= OnSocketEvent;
        rpc.Reconnected -= OnSocketReconnected;
    }

    /// The change on the rows: each bot named takes its working chats (BotStore.SetWorkingChats), the Sessions rows the
    /// working stored ids (SessionStore.SetRunning), and an ended turn drops the gateway's stale word for its chat.
    public void ApplyTo(TurnRowsChange change, BotStore bots, SessionStore sessions, DateTimeOffset? now = null)
    {
        foreach (var profile in change.Profiles) bots.SetWorkingChats(profile, Working.Chats(profile));
        sessions.SetRunning(Working.StoredIds);
        var dropped = false;
        foreach (var id in change.Ended) dropped |= sessions.TurnEnded(id);
        if (dropped) bots.SetLive(sessions.Live.Working, sessions.Live.Waiting);
        // [WIN-OFFSCREEN-TURN-END] `offScreenTurnEnded`: the reply landed while its chat was off screen, so the bot row
        // says so now with its dot, and the Sessions row shows it as the chat's newest message.
        foreach (var reply in change.Replies ?? [])
        {
            bots.NoteChatActivity(reply.Profile, reply.StoredId, reply.Text, now ?? DateTimeOffset.UtcNow, unseen: true, said: false);
            if (reply.StoredId is { } id) sessions.NoteLatest(reply.Profile, id, reply.Text, "assistant");
        }
        // [WIN-OFFSCREEN-END-REST] `noteTurnOutcome`: a standing problem is the bot row's orange status until a good
        // turn; `liveSteps.clear(runtime)`: the ended turn's step goes from its row.
        foreach (var outcome in change.Outcomes ?? [])
        {
            if (outcome.Failed) bots.NoteTurnFailed(outcome.Profile, outcome.Message, outcome.Reason);
            else bots.NoteTurnSucceeded(outcome.Profile);
        }
        foreach (var step in change.StepEnds ?? []) bots.EndStep(step.Profile, step.StoredId);
        if (change.Steps) PushSteps(bots, sessions);
    }

    /// [WIN-LIVE-STEPS] `pushSteps`: each heard chat's step goes to the lists by its chat's bot and stored id (a turn of
    /// ours running, else a chat on screen; "" for a chat not stored yet), as its row's line ("Reading package.json…").
    /// A step whose chat is neither is no row's.
    public void PushSteps(BotStore bots, SessionStore sessions)
    {
        var byBot = new Dictionary<string, Dictionary<string, string>>();   // profile → stored id ("" not stored yet) → line
        var bySession = new Dictionary<string, string>();
        lock (_gate)
        {
            foreach (var (runtime, words) in _steps.ByRuntime)
            {
                (string Profile, string? StoredId) owner;
                if (_running.TryGetValue(runtime, out var tracked)) owner = tracked;
                else if (_onScreen.FirstOrDefault(c => c.RuntimeId == runtime) is { } chat) owner = (chat.Profile, Id(chat.StoredId));
                else continue;
                var line = LiveSteps.Line(words);
                if (!byBot.TryGetValue(owner.Profile, out var chats)) byBot[owner.Profile] = chats = [];
                chats[owner.StoredId ?? ""] = line;
                if (owner.StoredId is { } id) bySession[id] = line;
            }
        }
        bots.SetSteps(byBot.ToDictionary(kv => kv.Key, kv => (IReadOnlyDictionary<string, string>)kv.Value));
        sessions.SetSteps(bySession);
    }

    private sealed class Leave(Action leave) : IDisposable
    {
        private int _done;
        public void Dispose() { if (Interlocked.Exchange(ref _done, 1) == 0) leave(); }
    }
}
