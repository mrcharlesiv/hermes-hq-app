using System.Text.Json.Nodes;
using Hermes.Core.Attachments;
using Hermes.Core.Model;
using Hermes.Core.Rpc;

namespace Hermes.Core.Chat;

/// The live fold of one chat: REST history plus the streaming turn (spec 04 §3–§5). Not thread-safe; ChatSession
/// calls it from one place. Every change replaces the touched message with a new value (bumped Revision).
public sealed class Transcript
{
    private readonly List<ChatMessage> _messages = [];
    private string? _liveId;          // the bubble deltas go into
    private bool _sealed;             // message.interim sealed it; the next delta opens a new bubble
    private bool _stopped;            // after Stop: drop stream frames until the next send
    private bool _stoppedTerminalPending;
    private long _lastSeq = -1;
    private int _localSeq;
    // [WIN-PROBLEM-CARD-REST] The send (its bubble's local id) still uploading and attaching its photos and files
    // (93f984bb1 LiveChatSession `turn.preparingSendId`): it has no turn on the gateway yet.
    private string? _preparingId;
    // Stop's reply belongs to one prompt, not the latest assistant in a later turn. Keep it in memory until the
    // session closes; even an authoritative page can lag (or never contain the interrupted partial).
    private sealed class InterruptedTurn(ChatMessage anchor, List<ChatMessage> replies, long? precedingRow)
    {
        public readonly string OriginalAnchorId = anchor.Id;
        public ChatMessage Anchor = anchor;
        public readonly List<ChatMessage> Replies = replies;
        public long? PrecedingRow = precedingRow;
        public bool AmbiguousPrompt;
        public long? NextUserRow;
    }
    private readonly List<InterruptedTurn> _interruptedTurns = [];
    private InterruptedTurn? _lastStoppedTurn;

    public IReadOnlyList<ChatMessage> Messages => _messages;
    public bool Busy { get; private set; }
    /// Provider-wait / tool status line ("thinking…", "terminal"). Not transcript content.
    public string? Status { get; private set; }
    /// The active model/provider fallback reported by `status.update`, cleared when primary restores.
    public ModelFallback? ActiveFallback { get; private set; }

    /// Replaces the transcript with a fresh REST page. While a turn streams, the live tail (messages not yet stored)
    /// is kept after the page so the reply doesn't blink.
    public void ReplaceWithHistory(IReadOnlyList<ChatMessage> page)
    {
        // Kept after the page: the live turn's local bubbles, local rows, fallback notices, and any message that failed
        // to send (its text is the user's, and the gateway never stored it).
        // A lost send's restored bubble is not kept here: the chat puts it back where it was said after the page
        // (ChatSession.RestoreLostSends), not at the end.
        var tail = _messages.Where(m => m.Id.StartsWith("local-") && (Busy || m.Error != null
                || m.Id.StartsWith(LocalRowPrefix, StringComparison.Ordinal)
                || m.Id.StartsWith(ProviderWait.NoticeIdPrefix, StringComparison.Ordinal))
            && !m.Id.StartsWith(LostPrefix, StringComparison.Ordinal)
            && !_endedAway.Contains(m.Id)   // [WIN-INFLIGHT-GRAFT] a turn of ours that ended while away: its stored rows
            && !_interruptedTurns.Any(t => t.Anchor.Id == m.Id || t.Replies.Any(r => r.Id == m.Id))).ToList();
        if (Busy && tail.FirstOrDefault(m => m.Role == Role.User) is { } localUser
            && page.LastOrDefault(m => m.Role == Role.User) is { } storedUser
            && (localUser.RowId is { } userRow ? storedUser.RowId == userRow
                : storedUser.Text == localUser.Text && !_interruptedTurns.Any(t => t.Anchor.Id == storedUser.Id
                    || (t.Anchor.RowId != null && t.Anchor.RowId == storedUser.RowId))))
            tail.Remove(localUser); // the prompt is persisted now
        // [WIN-INFLIGHT-GRAFT] The gateway's running or queued prompt, grafted in before it was stored: the page's own
        // row takes its place once the page holds it (the Mac's TranscriptMerge graft by words, 03 §4.5).
        var recentUsers = page.TakeLast(8).Where(m => m.Role == Role.User).Select(m => SentTitles.Flat(m.Text)).ToHashSet();
        tail.RemoveAll(m => (m.Id.StartsWith(InflightPrefix, StringComparison.Ordinal) || m.Id.StartsWith(QueuedPrefix, StringComparison.Ordinal))
            && recentUsers.Contains(SentTitles.Flat(m.Text)));
        _endedAway.Clear();
        foreach (var turn in _interruptedTurns)
        {
            turn.Anchor = _messages.FirstOrDefault(m => m.Id == turn.Anchor.Id) ?? turn.Anchor;
            for (var i = 0; i < turn.Replies.Count; i++)
                turn.Replies[i] = _messages.FirstOrDefault(m => m.Id == turn.Replies[i].Id) ?? turn.Replies[i];
            var anchorIndex = _messages.FindIndex(m => m.Id == turn.Anchor.Id);
            if (anchorIndex >= 0)
            {
                var laterUsers = _messages.Skip(anchorIndex + 1).Where(m => m.Role == Role.User).ToList();
                turn.AmbiguousPrompt |= laterUsers.Any(m => m.Text == turn.Anchor.Text);
                turn.NextUserRow ??= laterUsers.FirstOrDefault()?.RowId;
            }
        }
        _messages.Clear();
        _messages.AddRange(page);
        foreach (var turn in _interruptedTurns) MergeInterrupted(turn);
        _messages.AddRange(tail);
    }

    // The prompt is the boundary: compare replies only between it and the next user message. Row id wins; without
    // one, use a unique matching prompt newer than the rows seen before sending. Never match a previous prompt.
    private void MergeInterrupted(InterruptedTurn turn)
    {
        var anchor = _messages.FindIndex(m => m.Role == Role.User &&
            (turn.Anchor.RowId is { } row ? m.RowId == row : m.Id == turn.Anchor.Id));
        if (anchor < 0 && turn.Anchor.RowId == null && !turn.AmbiguousPrompt)
        {
            var candidates = _messages.Select((m, i) => (m, i)).Where(x => x.m.Role == Role.User
                && x.m.Text == turn.Anchor.Text && x.m.RowId is { } row
                && (turn.PrecedingRow == null || row > turn.PrecedingRow)).ToList();
            if (candidates.Count == 1) anchor = candidates[0].i;
        }
        if (anchor < 0)
        {
            anchor = turn.Anchor.RowId is { } row
                ? _messages.FindIndex(m => m.RowId is { } r && r > row)
                : turn.NextUserRow is { } next ? _messages.FindIndex(m => m.Role == Role.User && m.RowId == next) : -1;
            if (anchor < 0) anchor = _messages.Count;
            _messages.Insert(anchor, turn.Anchor);
        }
        else turn.Anchor = _messages[anchor];

        var end = _messages.FindIndex(anchor + 1, m => m.Role == Role.User);
        if (end < 0) end = _messages.Count;
        MergeReplies(turn.Replies, anchor + 1, end);
    }

    // Reserve known identities before matching any unpersisted bubbles by content. Two bubbles cannot claim
    // one gateway row. Put a still-missing bubble before its next matched sibling rather than at the very end.
    private void MergeReplies(List<ChatMessage> replies, int start, int end)
    {
        var matches = Enumerable.Repeat(-1, replies.Count).ToArray();
        var claimed = new HashSet<int>();
        void Match(Func<ChatMessage, ChatMessage, bool> accepts, bool unboundOnly)
        {
            for (var i = 0; i < replies.Count; i++)
            {
                var reply = replies[i];
                if (matches[i] >= 0 || (unboundOnly && reply.RowId != null)) continue;
                for (var j = start; j < end; j++)
                {
                    if (claimed.Contains(j) || _messages[j].Role != Role.Assistant || !accepts(reply, _messages[j])) continue;
                    matches[i] = j;
                    claimed.Add(j);
                    break;
                }
            }
        }
        Match((r, s) => s.Id == r.Id || (r.RowId != null && s.RowId == r.RowId), false);
        Match((r, s) => r.Text.Length > 0 && s.Text.Length > 0 && (s.Text.StartsWith(r.Text, StringComparison.Ordinal)
            || r.Text.StartsWith(s.Text, StringComparison.Ordinal)), true);
        Match((_, s) => string.IsNullOrWhiteSpace(s.Text), true);

        for (var i = 0; i < replies.Count; i++)
        {
            if (matches[i] < 0) continue;
            var stored = _messages[matches[i]];
            var shown = replies[i];
            // An authoritative rewrite wins. Only a missing or truncated prefix keeps the words already shown.
            var merged = string.IsNullOrWhiteSpace(stored.Text) && !string.IsNullOrWhiteSpace(shown.Text)
                ? stored with { Parts = shown.Parts }
                : shown.Text.StartsWith(stored.Text, StringComparison.Ordinal) ? WithFinalText(stored, shown.Text) : stored;
            replies[i] = merged with { Interrupted = shown.Interrupted, IsStreaming = false,
                Revision = Math.Max(shown.Revision, stored.Revision) + 1 };
            _messages[matches[i]] = replies[i];
        }
        // Insert from the front so saved indexes can be adjusted by the number inserted so far.
        var inserted = 0;
        for (var i = 0; i < replies.Count; i++)
        {
            if (matches[i] >= 0) continue;
            var next = Array.FindIndex(matches, i + 1, m => m >= 0);
            _messages.Insert((next < 0 ? end : matches[next]) + inserted++, replies[i]);
        }
    }

    /// The id a lost send's bubble comes back under (`restoreLostSends`: "local-user-lost-" and 8 hex digits).
    public const string LostPrefix = "local-user-lost-";

    /// Inserts a message inside the transcript (a lost send's bubble put back where it was said); at or past the end
    /// it is a plain append (LiveChatSession+Events.swift insertMessage).
    public void Insert(ChatMessage message, int index)
    {
        if (index >= _messages.Count) _messages.Add(message);
        else _messages.Insert(Math.Max(0, index), message);
    }

    /// Older rows prepended (paging back).
    public void PrependHistory(IReadOnlyList<ChatMessage> older)
    {
        var have = _messages.Select(m => m.Id).ToHashSet();
        _messages.InsertRange(0, older.Where(m => !have.Contains(m.Id)));
    }

    public ChatMessage AddLocalUser(string text) => AddLocalUser(text, []);

    /// Your bubble with its photos and files first (attachments: the tray's, from this PC's own copies).
    public ChatMessage AddLocalUser(string text, IReadOnlyList<ChatPart> attachments)
    {
        var m = new ChatMessage($"local-user-{++_localSeq}", Role.User, [.. attachments, new TextPart(text)], DateTimeOffset.Now,
            IsPending: true);
        _messages.Add(m);
        _stopped = false;
        Busy = true;
        Status = null;
        return m;
    }

    /// [WIN-PROBLEM-CARD-REST] A send with attachments begins uploading and attaching (`turn.preparingSendId = localId`).
    public void BeginPreparing(string localId) => _preparingId = localId;

    /// [WIN-PROBLEM-CARD-REST] Its attaches are done and `prompt.submit` goes (`endPreparing`), or it never goes.
    public void EndPreparing(string localId)
    {
        if (_preparingId == localId) _preparingId = null;
    }

    public void MarkSent(string localId, long? userRowId)
    {
        EndPreparing(localId);
        Update(localId, m => m with { IsPending = false, RowId = userRowId ?? m.RowId });
        foreach (var turn in _interruptedTurns.Where(t => t.OriginalAnchorId == localId))
            turn.Anchor = turn.Anchor with { IsPending = false, RowId = userRowId ?? turn.Anchor.RowId };
    }

    public void MarkFailed(string localId, string error)
    {
        EndPreparing(localId);
        Update(localId, m => m with { IsPending = false, Error = error });
        Busy = false;
        Status = null;
    }

    /// A send that never went out (refused or stopped before prompt.submit): its bubble goes and the chat is idle.
    public void Withdraw(string localId)
    {
        EndPreparing(localId);
        _messages.RemoveAll(m => m.Id == localId);
        _interruptedTurns.RemoveAll(t => t.OriginalAnchorId == localId);
        if (_lastStoppedTurn?.OriginalAnchorId == localId) _lastStoppedTurn = null;
        Busy = false;
        Status = null;
    }

    /// [WIN-UNDELIVERED-ACTIONS] One message goes and nothing else changes (LiveChatSession `removeMessage`): Send Again
    /// and Delete on an unconfirmed bubble, which may sit under a turn that is still running.
    public void Remove(string id) => _messages.RemoveAll(m => m.Id == id);

    /// Changes one message in place (a new value, bumped Revision): your bubble's attachments switching to their
    /// gateway copies.
    public void Revise(string id, Func<ChatMessage, ChatMessage> change) => Update(id, change);

    /// [chat actions] A rewind (Regenerate, Edit, Rewind to Here): the first `keep` messages stay, the rest go; returns
    /// what was there before so a refusal can put it back (LiveChatSession+ChatActions.swift rewindSubmit).
    public IReadOnlyList<ChatMessage> KeepFirst(int keep)
    {
        var before = _messages.ToList();
        if (keep < _messages.Count) _messages.RemoveRange(keep, _messages.Count - keep);
        if (_liveId != null && _messages.All(m => m.Id != _liveId)) { _liveId = null; _sealed = false; }
        return before;
    }

    /// [chat actions] A rewind's send was refused: the transcript as it was before, idle.
    public void Restore(IReadOnlyList<ChatMessage> snapshot)
    {
        _messages.Clear();
        _messages.AddRange(snapshot);
        _liveId = null;
        _sealed = false;
        Busy = false;
        Status = null;
    }

    /// Stop, locally first: seal the live bubble and go idle.
    public void Stop()
    {
        if (_stopped) return;
        _lastStoppedTurn = null;
        if (_liveId != null) Update(_liveId, m => m with { IsStreaming = false, Interrupted = true });
        var anchorIndex = _messages.FindLastIndex(m => m.Role == Role.User);
        if (Busy && anchorIndex >= 0)
        {
            var replies = _messages.Skip(anchorIndex + 1).Where(m => m.Id.StartsWith("local-assistant-") && m.Parts.Count > 0).ToList();
            var precedingRow = _messages.Take(anchorIndex).Max(m => m.RowId);
            _lastStoppedTurn = new InterruptedTurn(_messages[anchorIndex], replies, precedingRow);
            _interruptedTurns.Add(_lastStoppedTurn);
        }
        _liveId = null;
        _stopped = true;
        _stoppedTerminalPending = true;
        Busy = false;
        Status = null;
    }

    /// Session resume snapshot: a turn already running server-side.
    public void AdoptRunning(bool running) { if (running) { Busy = true; _stopped = false; } }

    // ------------------------------------------------------------------ [WIN-INFLIGHT-GRAFT] the gateway's snapshot

    /// The bubble of a running turn's prompt the chat didn't show (the Mac's "local-user-inflight-N").
    public const string InflightPrefix = "local-user-inflight-";
    /// The bubble of the gateway's queued prompt (the Mac's "local-user-queued-N").
    public const string QueuedPrefix = "local-user-queued-";
    private readonly HashSet<string> _endedAway = [];

    /// A prompt bubble from the snapshot (`prefix` InflightPrefix or QueuedPrefix): delivered, not pending.
    public string AddGrafted(string prefix, string text, DateTimeOffset at)
    {
        var m = new ChatMessage($"{prefix}{++_localSeq}", Role.User, [new TextPart(text)], at);
        _messages.Add(m);
        return m.Id;
    }

    /// The snapshot says nothing runs and the turn left streaming ended while away (`graftInflight`'s `!running`
    /// branch when busy and live): its live bubble is sealed, running tools say "Result unavailable", the chat is idle.
    /// False when no live turn was on show.
    public bool SettleAway()
    {
        if (!Busy || _liveId == null) return false;
        Settle();
        return true;
    }

    /// The turn running now isn't the one we left (the reconnect's anchor check): our live bubble is sealed (it takes
    /// its stored reply in the read), and our prompt and replies are not carried as the new turn's at the next read.
    /// The chat stays busy: the new turn runs.
    public void EndTurnAway(string anchorId)
    {
        if (_liveId != null)
            Update(_liveId, m => m with
            {
                IsStreaming = false,
                Parts = [.. m.Parts.Select(x => x is ToolPart { Call.State: ToolState.Running } t
                    ? new ToolPart(t.Call with { State = ToolState.Done, Summary = t.Call.Summary ?? "Result unavailable" }) : x)],
            });
        _liveId = null;
        _sealed = false;
        var anchor = _messages.FindIndex(m => m.Id == anchorId);
        if (anchor < 0) return;
        _endedAway.Add(anchorId);
        foreach (var m in _messages.Skip(anchor + 1).TakeWhile(m => m.Role != Role.User))
            if (m.Id.StartsWith("local-assistant-", StringComparison.Ordinal)) _endedAway.Add(m.Id);
    }

    /// [WIN-COMPOSER-CARD-IDS] `Problem`: an `error` frame that arrived with no turn of ours in flight (the words are in
    /// `ProblemText`); the chat raises its problem card from it (LiveChatSession+Events.swift `SessionProblem.make`).
    public enum Outcome { None, Changed, TurnEnded, Problem }

    /// The words of the last `error` frame that came with no turn in flight (Outcome.Problem).
    public string? ProblemText { get; private set; }

    public Outcome Apply(RpcEvent e)
    {
        if (e.Seq is { } seq)
        {
            if (seq <= _lastSeq) return Outcome.None;
            _lastSeq = seq;
        }
        var p = e.Payload;
        switch (e.Type)
        {
            case "message.start":
                if (_stopped) return Outcome.None;
                Busy = true;
                OpenBubble();
                return Outcome.Changed;
            case "message.delta":
                if (_stopped) return Outcome.None;
                AppendText(HistoryFold.Coerce(p.Get("text")), reasoning: false);
                return Outcome.Changed;
            case "reasoning.delta":
                if (_stopped) return Outcome.None;
                AppendText(HistoryFold.Coerce(p.Get("text")), reasoning: true);
                return Outcome.Changed;
            case "reasoning.available":
                if (_stopped) return Outcome.None;
                var whole = HistoryFold.Coerce(p.Get("text"));
                Update(Live(), m => m.Text.Length > 0 ? m
                    : m with { Parts = [new ReasoningPart(whole), .. m.Parts.Where(x => x is not ReasoningPart)] });
                return Outcome.Changed;
            case "thinking.delta":
                Status = HistoryFold.Coerce(p.Get("text")).Trim() is { Length: > 0 } t ? t : "Thinking…";
                return Outcome.Changed;
            case "tool.generating":
                if (_stopped) return Outcome.None;
                Status = p.Text("name") is { } n ? $"Writing {n} call…" : null;
                return Outcome.Changed;
            case "message.interim":
                if (_stopped) return Outcome.None;
                var interim = HistoryFold.Coerce(p.Get("text"));
                if (interim.Length > 0) Update(Live(), m => WithFinalText(m, interim));
                Update(Live(), m => m with { IsStreaming = false });
                _sealed = true;
                return Outcome.Changed;
            case "tool.start":
                if (_stopped) return Outcome.None;
                ToolStart(p);
                return Outcome.Changed;
            case "tool.complete":
                ToolComplete(p);
                return Outcome.Changed;
            case "message.complete":
                return Complete(p);
            case "session.info":
                if (p.Bool("running") == false && Busy && _liveId != null) { Settle(); return Outcome.TurnEnded; }
                return Outcome.None;
            case "error":
                var msg = p.Get("message") is JsonObject mo ? mo.Text("message") ?? mo.ToJsonString() : p.Text("message");
                // [WIN-COMPOSER-CARD-IDS] A chat-level failure with no turn in flight (LiveChatSession+Events.swift: `guard
                // inFlight, !turn.interrupted else { … sessionProblem = SessionProblem.make(…) }`): a card above the
                // composer, not an error row. A stopped turn whose end hasn't come yet is the Mac's `interrupted`: as before.
                // [WIN-PROBLEM-CARD-REST] A send still uploading has no turn on the gateway yet: an error now isn't about
                // it (`let preparing = turn.preparingSendId != nil && turn.streamId == nil`), and the send goes on.
                var preparing = _preparingId != null && _liveId == null;
                if ((preparing || (!Busy && _liveId == null)) && !_stoppedTerminalPending)
                {
                    ProblemText = msg ?? "";
                    return Outcome.Problem;
                }
                if (msg != null && System.Text.RegularExpressions.Regex.IsMatch(msg,
                        "^(Turn cancelled|Session no longer running) before the agent was ready",
                        System.Text.RegularExpressions.RegexOptions.IgnoreCase))
                { Stop(); return Outcome.TurnEnded; }
                if (_stopped) return Outcome.None;
                AddSystem(msg ?? "Something went wrong.", error: true);
                Settle();
                return Outcome.TurnEnded;
            case "status.update":
                var kind = p.Str("kind");
                if (ProviderWait.FallbackNotice(kind, p.Text("text") ?? p.Text("message")) is { } fallbackText)
                {
                    if (ModelFallback.Parse(fallbackText) is { } parsedFallback) ActiveFallback = parsedFallback;
                    else if (ModelFallback.Restores(fallbackText)) ActiveFallback = null;
                    var last = _messages.Count > 0 ? _messages[^1] : null;
                    if (last == null || last.Role != Role.System || last.Text != fallbackText)
                    {
                        _messages.Add(new ChatMessage($"{ProviderWait.NoticeIdPrefix}{++_localSeq}", Role.System,
                            [new TextPart(fallbackText)], DateTimeOffset.Now));
                    }
                    return Outcome.Changed;
                }
                Status = kind is "compacting" or "compressing" ? "Summarizing the chat…" : kind is "compacted" or "ready" ? null : Status;
                return Outcome.Changed;
            default:
                return Outcome.None;
        }
    }

    private Outcome Complete(JsonNode? p)
    {
        var text = HistoryFold.Coerce(p.Get("text"));
        var status = p.Str("status");
        var userRow = p.Obj("persisted_turn").Int("user_row_id");
        // A named end belongs to its prompt, even if Stop happened before the first delta or a later turn
        // has already stopped too. It must not overwrite a new stream or release a different pending Stop.
        var current = _messages.FindLastIndex(m => m.Role == Role.User);
        if (userRow is { } row && current >= 0 && _messages[current].RowId != row)
        {
            var prior = _interruptedTurns.LastOrDefault(t => t.Anchor.RowId == row);
            if (prior != null || _messages.Take(current).Any(m => m.Role == Role.User && m.RowId == row))
            {
                if (status == "interrupted" && prior != null) ExtendStopped(prior, text);
                if (prior != null && prior == _lastStoppedTurn) _stoppedTerminalPending = false;
                return Outcome.Changed;
            }
        }
        if (!_stopped && Busy && userRow == null && status == "interrupted" && _stoppedTerminalPending)
        {
            if (_lastStoppedTurn != null) ExtendStopped(_lastStoppedTurn, text);
            _stoppedTerminalPending = false;
            return Outcome.Changed;
        }
        if (_stopped)
        {
            _stoppedTerminalPending = false;
            if (status == "interrupted" && _lastStoppedTurn is { } stopped
                && (userRow == null || stopped.Anchor.RowId == null || userRow == stopped.Anchor.RowId))
                ExtendStopped(stopped, text);
            return Outcome.TurnEnded;
        }
        if (text.Length > 0) Update(Live(), m => WithFinalText(m, text));
        var rowId = p.Obj("persisted_turn").Int("final_assistant_row_id") ?? p.Int("row_id");
        if (_liveId != null)
            Update(_liveId, m => m with
            {
                RowId = rowId ?? m.RowId,
                Error = status == "error" ? p.Text("error") ?? "The reply failed." : null,
            });
        Settle();
        return Outcome.TurnEnded;
    }

    private void ExtendStopped(InterruptedTurn turn, string text)
    {
        if (turn.Replies.Count == 0) return;
        var last = turn.Replies[^1];
        var shown = _messages.FirstOrDefault(m => m.Id == last.Id) ?? last;
        if (shown.Text.Length == 0 || text.Length <= shown.Text.Length
            || !text.StartsWith(shown.Text, StringComparison.Ordinal)) return;
        turn.Replies[^1] = WithFinalText(shown, text) with { Revision = shown.Revision + 1 };
        var index = _messages.FindIndex(m => m.Id == shown.Id);
        if (index >= 0) _messages[index] = turn.Replies[^1];
    }

    private void Settle()
    {
        if (_liveId != null)
            Update(_liveId, m => m with
            {
                IsStreaming = false,
                Parts = [.. m.Parts.Select(x => x is ToolPart { Call.State: ToolState.Running } t
                    ? new ToolPart(t.Call with { State = ToolState.Done, Summary = t.Call.Summary ?? "Result unavailable" }) : x)],
            });
        _liveId = null;
        _sealed = false;
        Busy = false;
        Status = null;
    }

    /// The authoritative text for the whole turn. It never wipes streamed text. When it extends what's shown, the
    /// remainder goes on the last text part; when the bubble has no tools it replaces the text; otherwise the
    /// streamed parts stay and the turn-end history read corrects them.
    private static ChatMessage WithFinalText(ChatMessage m, string text)
    {
        var shown = m.Text;
        if (text == shown || text.Length == 0) return m;
        var parts = m.Parts.ToList();
        if (text.StartsWith(shown))
        {
            var rest = text[shown.Length..];
            var lastText = parts.FindLastIndex(x => x is TextPart);
            if (lastText >= 0 && lastText == parts.Count - 1) parts[lastText] = new TextPart(((TextPart)parts[lastText]).Text + rest);
            else parts.Add(new TextPart(rest));
        }
        else if (!parts.Any(x => x is ToolPart))
        {
            parts.RemoveAll(x => x is TextPart);
            parts.Add(new TextPart(text));
        }
        else return m;
        return m with { Parts = parts };
    }

    private string OpenBubble()
    {
        var m = new ChatMessage($"local-assistant-{++_localSeq}", Role.Assistant, [], DateTimeOffset.Now, IsStreaming: true);
        _messages.Add(m);
        _liveId = m.Id;
        _sealed = false;
        Status = null;
        return m.Id;
    }

    /// The bubble stream frames go into, opening one if a turn began without message.start or after an interim.
    private string Live() => _liveId != null && !_sealed ? _liveId : OpenBubble();

    private void AppendText(string chunk, bool reasoning)
    {
        if (chunk.Length == 0) return;
        Busy = true;
        Status = null;
        Update(Live(), m =>
        {
            var parts = m.Parts.ToList();
            if (parts.Count > 0 && reasoning && parts[^1] is ReasoningPart r) parts[^1] = new ReasoningPart(r.Text + chunk);
            else if (parts.Count > 0 && !reasoning && parts[^1] is TextPart t) parts[^1] = new TextPart(t.Text + chunk);
            else parts.Add(reasoning ? new ReasoningPart(chunk) : new TextPart(chunk));
            return m with { Parts = parts };
        });
    }

    private void ToolStart(JsonNode? p)
    {
        var id = p.Text("tool_id") ?? $"tool-{++_localSeq}";
        var call = new ToolCall(id, p.Text("name") ?? "tool",
            HistoryFold.ArgsText(p.Get("args")) ?? p.Text("args_text") ?? p.Text("preview") ?? p.Text("context"),
            null, ToolState.Running, ArgsJson: HistoryFold.ArgsJson(p.Get("args")) ?? p.Text("args_text"));
        Status = null;
        Update(Live(), m =>
        {
            var parts = m.Parts.ToList();
            var at = parts.FindIndex(x => x is ToolPart tp && tp.Call.Id == id);
            if (at >= 0) parts[at] = new ToolPart(call); else parts.Add(new ToolPart(call));
            return m with { Parts = parts };
        });
    }

    /// May target an earlier, already-sealed bubble.
    private void ToolComplete(JsonNode? p)
    {
        var id = p.Text("tool_id");
        for (var i = _messages.Count - 1; i >= 0; i--)
        {
            var m = _messages[i];
            var at = m.Parts.ToList().FindIndex(x => x is ToolPart tp && (tp.Call.Id == id || (id == null && tp.Call.State == ToolState.Running)));
            if (at < 0) continue;
            var call = ((ToolPart)m.Parts[at]).Call;
            var failed = p.Get("error") is { } err && HistoryFold.Coerce(err).Length > 0;
            var result = p.Get("result");
            var summary = p.Text("summary") ?? p.Text("result_text")
                ?? HistoryFold.Summary(result is JsonValue ? J.AsString(result) : result?.ToJsonString());
            var parts = m.Parts.ToList();
            parts[at] = new ToolPart(call with
            {
                State = failed ? ToolState.Failed : ToolState.Done,
                Summary = failed ? HistoryFold.Coerce(p.Get("error")) : summary,
                DurationSeconds = p.Num("duration_s"),
                ArgsText = call.ArgsText ?? HistoryFold.ArgsText(p.Get("args")),
                ArgsJson = call.ArgsJson ?? HistoryFold.ArgsJson(p.Get("args")),
                ResultText = HistoryFold.Bounded(failed ? HistoryFold.Coerce(p.Get("error"))
                    : result is JsonValue ? J.AsString(result) : result?.ToJsonString() ?? p.Text("result_text")),
            });
            if (GeneratedImages.FromComplete(call.Id, call.Name, p, failed) is { } picture) parts[at] = picture;
            _messages[i] = m with { Parts = parts, Revision = m.Revision + 1 };
            return;
        }
    }

    public void SetReactions(string id, IReadOnlyList<Hermes.Core.Transcripts.MessageReaction> reactions) =>
        Update(id, m => m with { Reactions = reactions });
    // ------------------------------------------------------------------ [composer] steers and local rows

    /// Rows the composer adds that are never stored (slash output): kept across history reads.
    public const string LocalRowPrefix = "local-row-";
    private readonly Dictionary<string, (string? Sealed, bool WasStreaming)> _steers = [];

    /// A Stop is still unwinding: typed words wait in the queue rather than steer.
    public bool StopUnwinding => _stopped && Busy;

    /// Seals the live bubble where it stands and adds the pending bubble under it; what the bot says next lands below.
    public string BeginSteer(string shown)
    {
        string? sealedId = _liveId != null && !_sealed ? _liveId : null;
        var wasStreaming = sealedId != null && _messages.Find(m => m.Id == sealedId)?.IsStreaming == true;
        if (sealedId != null)
        {
            Update(sealedId, m => m with { IsStreaming = false });
            _sealed = true;
        }
        var m = new ChatMessage($"local-user-steer-{++_localSeq}", Role.User, [new TextPart(shown)], DateTimeOffset.Now, IsPending: true);
        _messages.Add(m);
        _steers[m.Id] = (sealedId, wasStreaming);
        return m.Id;
    }

    /// `redirected`: part of the running reply now.
    public void SteerTaken(string id)
    {
        _steers.Remove(id);
        Update(id, m => m with { IsPending = false });
    }

    /// `queued`: the next turn's prompt; the reply goes on in its own bubble, this one moves to the newest end.
    public void SteerNextTurn(string id)
    {
        Unseal(id);
        var i = _messages.FindLastIndex(m => m.Id == id);
        if (i < 0) return;
        var m = _messages[i];
        _messages.RemoveAt(i);
        _messages.Add(m with { IsPending = false, Revision = m.Revision + 1 });
    }

    /// Not taken: the bubble goes, and the reply carries on in the bubble it was sealed out of.
    public void SteerFailed(string id)
    {
        Unseal(id);
        _messages.RemoveAll(m => m.Id == id);
    }

    private void Unseal(string id)
    {
        if (!_steers.Remove(id, out var s) || s.Sealed is not { } sid) return;
        // Only when nothing opened since: the turn still runs and the bot hasn't gone on in a new bubble.
        if (!Busy || _liveId != sid || !_sealed) return;
        _sealed = false;
        if (s.WasStreaming) Update(sid, m => m with { IsStreaming = true });
    }

    public string AddLocal(Role role, ChatPart part)
    {
        var m = new ChatMessage($"{LocalRowPrefix}{++_localSeq}", role, [part], DateTimeOffset.Now);
        _messages.Add(m);
        return m.Id;
    }

    public void ReplaceLocal(string id, ChatPart? part)
    {
        if (part == null) { _messages.RemoveAll(m => m.Id == id); return; }
        Update(id, m => m with { Parts = [part] });
    }

    public void AddSystem(string text, bool error = false) =>
        _messages.Add(new ChatMessage($"local-system-{++_localSeq}", Role.System, [new TextPart(text)], DateTimeOffset.Now,
            Error: error ? text : null));

    private void Update(string id, Func<ChatMessage, ChatMessage> change)
    {
        var i = _messages.FindLastIndex(m => m.Id == id);
        if (i < 0) return;
        var before = _messages[i];
        var after = change(before);
        if (!ReferenceEquals(before, after)) _messages[i] = after with { Revision = before.Revision + 1 };
    }
}
