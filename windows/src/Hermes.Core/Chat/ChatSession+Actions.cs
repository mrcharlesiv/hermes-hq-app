using System.Text.Json.Nodes;
using Hermes.Core.Model;
using Hermes.Core.Net;

namespace Hermes.Core.Chat;

/// [chat actions] Branch in New Chat (`session.branch {session_id, count}` from a message, `session.branch_stored`
/// for the whole chat, `session.create` with the messages on an older gateway) and the rewinds — Regenerate, Edit and
/// Rewind to Here — which are `prompt.submit` truncating before a stored user row (HermesKit/Chat/
/// LiveChatSession+ChatActions.swift).
public sealed partial class ChatSession
{
    /// A new chat from the whole chat (null) or from the start through a message.
    public async Task<ChatBranchResult> BranchAsync(string? messageId, CancellationToken ct = default)
    {
        JsonNode result;
        if (messageId != null)
        {
            if (Busy) throw new GatewayException("branch", ChatActionWords.StopBeforeBranch);
            var target = Messages.FirstOrDefault(m => m.Id == messageId) ?? throw new GatewayException("branch", ChatActionWords.NotInChat);
            if (target.Id.StartsWith("local-", StringComparison.Ordinal) && target.RowId == null)
                throw new GatewayException("branch", ChatActionWords.NotSaved);
            var whole = Messages;
            if (_hasOlder)
                whole = (await _client.HistoryAsync(Profile, StoredId, 500, 0, ct)).Messages;
            var id = whole.Any(m => m.Id == messageId) ? messageId
                : target.RowId is { } row ? whole.LastOrDefault(m => m.RowId == row)?.Id : null;
            if (id == null || RewindParams.BranchCount(id, whole) is not { } count)
                throw new GatewayException("branch", ChatActionWords.NotSaved);
            result = await CallAsync("session.branch", new JsonObject { ["count"] = count }, TimeSpan.FromSeconds(60), SessionNeed.ResumeFirst, ct);
        }
        else
        {
            var p = new JsonObject { ["cols"] = 96, ["source"] = "desktop", ["parent_session_id"] = StoredId, ["profile"] = Profile };
            if (Cwd is { Length: > 0 } cwd) p["cwd"] = cwd;
            try { result = await _client.Rpc.RequestAsync("session.branch_stored", p, TimeSpan.FromSeconds(60), ct); }
            catch (GatewayException e) when (e.RpcCode == -32601 || e.Message.Contains("method not found", StringComparison.OrdinalIgnoreCase)
                || e.Message.Contains("unknown method", StringComparison.OrdinalIgnoreCase))
            {
                var rows = (await _client.HistoryAsync(Profile, StoredId, 500, 0, ct)).Messages;
                var plain = new JsonArray();
                foreach (var m in rows.Where(m => m.Role is Role.User or Role.Assistant))
                {
                    var text = Transcripts.MessageMenu.Blocks(m);
                    if (text.Length > 0) plain.Add(new JsonObject { ["role"] = m.Role == Role.User ? "user" : "assistant", ["content"] = text });
                }
                if (plain.Count == 0) throw new GatewayException("branch", ChatActionWords.NothingToBranch);
                p["messages"] = plain;
                result = await _client.Rpc.RequestAsync("session.create", p, TimeSpan.FromSeconds(60), ct);
            }
        }
        var runtime = result.Text("session_id");
        var stored = result.Text("stored_session_id") ?? runtime
            ?? throw new GatewayException("branch", ChatActionWords.BranchShape);
        return new ChatBranchResult(stored, runtime);
    }

    /// The chat's folder as the gateway last reported it (`session.info` / resume's `cwd`); Branch passes it on.
    public string? Cwd { get; private set; }

    /// Whether this message can be edited / rewound to: your stored text message.
    public bool CanRewind(string messageId) =>
        Messages.FirstOrDefault(m => m.Id == messageId) is { } m && ChatActionRules.CanRewind(m);

    /// Sends the latest reply's prompt again in place of the reply. False when there is nothing to regenerate.
    public bool Regenerate(Action<string> onFailed)
    {
        if (Busy) return false;
        var messages = Messages;
        if (ChatActionRules.RegeneratePrompt(messages) is not { } prompt || !ChatActionRules.CanRewind(messages[prompt])) return false;
        return RewindSubmit(prompt, messages[prompt].Text, onFailed);
    }

    /// Your message, sent again as `text` with everything from it on removed (Edit). An unchanged edit sends nothing
    /// and answers true. False when it can't be addressed.
    public bool Edit(string messageId, string text, Action<string> onFailed)
    {
        var messages = Messages;
        var index = IndexOf(messages, messageId);
        if (index < 0 || !ChatActionRules.CanRewind(messages[index])) return false;
        if (text.Trim().Length == 0) return false;
        if (ChatActionRules.EditedText(messages[index], text) is not { } typed) return true;
        return RewindSubmit(index, typed, onFailed);
    }

    /// Everything after your message removed; it runs again from there (Rewind to Here).
    public bool Rewind(string messageId, Action<string> onFailed)
    {
        var messages = Messages;
        var index = IndexOf(messages, messageId);
        if (index < 0 || !ChatActionRules.CanRewind(messages[index])) return false;
        return RewindSubmit(index, messages[index].Text, onFailed);
    }

    /// The last rewind's send (tests and the walk wait on it).
    public Task? RewindSend { get; private set; }

    private static int IndexOf(IReadOnlyList<ChatMessage> messages, string id)
    {
        for (var i = 0; i < messages.Count; i++) if (messages[i].Id == id) return i;
        return -1;
    }

    /// Removes the user turn at `index` and everything after it, then sends `text` truncating before that turn's row.
    /// A running reply is stopped first.
    private bool RewindSubmit(int index, string text, Action<string> onFailed)
    {
        IReadOnlyList<ChatMessage> snapshot;
        JsonObject extra;
        ChatMessage local;
        lock (_lock)
        {
            if (index >= _t.Messages.Count || _t.Messages[index].RowId is not { } row) return false;
            if (_t.Busy) _t.Stop();
            var loaded = _t.Messages.Where(m => m.RowId is not null).Select(m => m.RowId!.Value).ToList();
            extra = RewindParams.Make(row, loaded);
            snapshot = _t.KeepFirst(index);
            local = _t.AddLocalUser(text);
        }
        _stopPending = false;
        TurnInterrupted = false;
        _turnStarted = DateTimeOffset.Now;
        _turnPrompt = text;
        Changed?.Invoke();
        RewindSend = SendRewindAsync(local.Id, text, extra, snapshot, onFailed);
        return true;
    }

    private async Task SendRewindAsync(string localId, string text, JsonObject extra, IReadOnlyList<ChatMessage> snapshot,
        Action<string> onFailed)
    {
        var submitted = false;
        try
        {
            var runtime = await ResumeAsync(CancellationToken.None);
            JsonNode res;
            submitted = true;
            try { res = await Submit(runtime, text, CancellationToken.None, extra: extra, localId: localId); }
            catch (GatewayException e) when (e.RpcCode is 4001 or 4007)
            {
                _runtimeId = null;
                res = await Submit(await ResumeAsync(CancellationToken.None), text, CancellationToken.None, extra: extra, localId: localId);
            }
            var map = RewindParams.SurvivorMap(res);
            lock (_lock)
            {
                _t.MarkSent(localId, res.Int("user_row_id"));
                foreach (var m in _t.Messages.ToList())
                    if (m.RowId is { } old && map.TryGetValue(old, out var mapped)) _t.Revise(m.Id, x => x with { RowId = mapped });
            }
            Changed?.Invoke();
        }
        catch (GatewayException e)
        {
            if (submitted && MayHaveGoneOut(e))   // [WIN-SEND-NOTSENT-REFUSE] a not-sent one is refused
            {
                lock (_lock) _t.MarkFailed(localId, "Delivery unconfirmed");
                Changed?.Invoke();
                return;
            }
            // The rewind was refused: the transcript as it was before, and the reason to whoever asked.
            lock (_lock) _t.Restore(snapshot);
            Changed?.Invoke();
            onFailed(e.Message.Trim().Length == 0 ? ChatActionWords.NotAccepted : e.Message);
        }
    }
}
