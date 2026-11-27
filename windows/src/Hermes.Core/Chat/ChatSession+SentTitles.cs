// [WIN-SENT-TITLES] The chat's side of a titled request (93f984bb1 HermesKit/Presence/SentTitles.swift, used from
// LiveChatSession.swift and LiveChatSession+Sync.swift): every read of stored rows (the cache paint, the newest page,
// older pages) shows a titled prompt as its title (`applied(to:)`, ChatSession.cs); a title sent again from the main
// bot's field goes out as its request (`sendAfterOpen`: ChatSession.SendAsync, and ChatComposer.Send before the steer
// decision); Check looks for the request (ChatSession+Undelivered.cs).
//
// [WIN-INFLIGHT-GRAFT] And the gateway's snapshot, from a `session.resume` or `session.activate` answer
// (LiveChatSession+Sync.swift `graftInflight` / `graftInflightTurn`, 03 §4.5, 04 §2.5, §7.3–7.4):
//  - running: a turn the chat didn't see start makes it busy; "nothing runs" settles a turn left streaming (it ended
//    while away: its live bubble sealed, then a read and the queue's drain).
//  - the inflight prompt: when it is the newest bubble shown (by its words, the request its title stands for, or the
//    turn's anchor key), that bubble is the running turn's (`userAnchorId` / `anchorPromptKey`), and a "Delivery
//    unconfirmed" mark on it goes with its kept lost send; otherwise its bubble goes in ("local-user-inflight-",
//    showing its title when it is a titled request) so the running reply sits under its prompt.
//  - the queued prompt: its bubble ("local-user-queued-") unless one of the last three rows says it.
//  - the reconnect's anchor check: when the turn running now is not the one we left (our anchor's words, its anchor
//    key and its title's request all differ), our live bubble is sealed, our turn is not carried as the new one's, and
//    the chat reads its rows (the Mac's forced read).
// Not ported: the reply text the snapshot carries (the Mac's "local-assistant-inflight-" bubble and stored-partial
// fold), the steer corrections (`InflightCorrections`), a helper's note as the turn's prompt (`inflightNote`), and the
// cut by the running turn's prompt (`liveTurnUserIndex`, which Windows' whole-page read has no counterpart of).
// Differences: a titled bubble matches by the request it stands for (the Mac compares the bubble's words alone, so it
// adds a second bubble for its own titled request and its graft misses a lost titled send); a steer bubble is never
// taken for the turn's prompt, nor a queued bubble with other words (the Mac adds the running prompt again under its
// own queued bubble at the next snapshot); "nothing runs" counts only when the answer says `running: false`.

using System.Text.Json.Nodes;
using Hermes.Core.Model;

namespace Hermes.Core.Chat;

public sealed partial class ChatSession
{
    /// The app's titled requests (HermesClient.SentTitles; SentTitles.Shared in the app).
    public SentTitles SentTitles => _client.SentTitles;

    // [WIN-INFLIGHT-GRAFT] The running turn's prompt (`turn.userAnchorId` / `turn.anchorPromptKey`): our own send's
    // bubble and the words it sent, or the bubble the snapshot named. Guarded by _lock.
    private string? _anchorId;
    private string? _anchorPromptKey;

    /// A send of ours started its turn: its bubble anchors it, by the words that went out.
    private void AnchorTurn(string localId, string sent)
    {
        lock (_lock) { _anchorId = localId; _anchorPromptKey = DisplayKey(sent); }
    }

    /// A `session.resume` / `session.activate` answer (see above). `resuming`: a resume still binding (its `running`
    /// says nothing yet). True when it settled a turn that ended while away (the caller reads the rows).
    internal bool GraftInflight(JsonNode? snapshot, bool resuming = false)
    {
        if (snapshot is not JsonObject) return false;
        var running = snapshot.Bool("running") == true && !resuming;
        var idle = snapshot.Bool("running") == false && !resuming;
        string? cleared = null;
        var settled = false;
        lock (_lock)
        {
            if (running && !TurnInterrupted)
            {
                // A turn we didn't see start: its own prompt is set by the inflight graft below, if it has one.
                if (!_t.Busy) { _anchorId = null; _anchorPromptKey = null; }
                _t.AdoptRunning(true);
            }
            else if (idle) settled = _t.SettleAway();
            if (snapshot.Get("inflight") is JsonObject inflight && inflight.Text("user") is { } user)
            {
                var key = DisplayKey(user);
                // The newest prompt shown, past steers and past a queued bubble that isn't this prompt (it waits behind it).
                var last = _t.Messages.LastOrDefault(m => m.Role == Role.User
                    && !m.Id.StartsWith("local-user-steer-", StringComparison.Ordinal)
                    && !(m.Id.StartsWith(Transcript.QueuedPrefix, StringComparison.Ordinal) && !IsPrompt(m, key)));
                if (last == null || !IsPrompt(last, key))
                {
                    var id = _t.AddGrafted(Transcript.InflightPrefix, SentTitles.Title(user) ?? user.Trim(), TurnStartedAt(snapshot));
                    if (running) { _anchorId = id; _anchorPromptKey = key; }
                }
                else
                {
                    if (running) { _anchorId = last.Id; _anchorPromptKey = key; }
                    // The gateway holds this prompt: a send whose ack was lost was delivered after all (04 §2.5).
                    if (last.Id.StartsWith("local-", StringComparison.Ordinal) && last.Error == UnconfirmedMark)
                    {
                        _t.Revise(last.Id, m => m with { Error = null });
                        cleared = last.Id;
                    }
                }
            }
            if (snapshot.Get("queued") is JsonObject queuedTurn && queuedTurn.Text("user") is { } queued)
            {
                var key = DisplayKey(queued);
                if (!_t.Messages.TakeLast(3).Any(m => m.Role == Role.User && IsPrompt(m, key)))
                    _t.AddGrafted(Transcript.QueuedPrefix, SentTitles.Title(queued) ?? queued.Trim(), DateTimeOffset.Now);
            }
        }
        if (cleared != null) ClearLostSend(cleared);                          // [sessions-m9]
        Changed?.Invoke();
        if (settled) TurnEnded?.Invoke(true);
        return settled;
    }

    private static DateTimeOffset TurnStartedAt(JsonNode snapshot) =>
        snapshot.Get("turn_started_at") is JsonValue v && v.TryGetValue<double>(out var seconds) && seconds > 0
            ? DateTimeOffset.FromUnixTimeMilliseconds((long)(seconds * 1000)) : DateTimeOffset.Now;

    /// `bubble` shows the prompt `key` names: by its words, the request its title stands for, or the anchor key of the
    /// turn it anchors. Under _lock.
    private bool IsPrompt(ChatMessage bubble, string key) =>
        DisplayKey(bubble.Text) == key
        || SentTitles.Prompt(bubble.Text) is { } prompt && DisplayKey(prompt) == key
        || bubble.Id == _anchorId && _anchorPromptKey == key;

    /// The reconnect's check (LiveChatSession+Sync.swift, the activate path): the turn running now is not the one we
    /// left (ours ended and a queued or delivered one started while away), so our live bubble is sealed and our turn is
    /// not carried as the new one's. True when it did: the caller reads the rows.
    private bool EndOwnTurnIfAnotherRuns(JsonNode? snapshot)
    {
        if (snapshot.Bool("running") != true || snapshot.Get("inflight") is not JsonObject inflight
            || inflight.Text("user") is not { } user) return false;
        var key = DisplayKey(user);
        lock (_lock)
        {
            if (!_t.Busy || _anchorId is not { } anchor || _t.Messages.LastOrDefault(m => m.Id == anchor) is not { } bubble) return false;
            if (DisplayKey(bubble.Text) == key) return false;
            // Our own turn still running matches by the prompt it sent too: a skill, titled request or attachment send
            // shows other text in its bubble than `inflight.user` names.
            if ((_anchorPromptKey ?? DisplayKey(SentTitles.Prompt(bubble.Text) ?? bubble.Text)) == key) return false;
            _t.EndTurnAway(anchor);
            _anchorId = null;
            _anchorPromptKey = null;
        }
        Changed?.Invoke();
        return true;
    }
}
