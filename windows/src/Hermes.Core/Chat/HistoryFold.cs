using System.Text.Json;
using System.Text.Json.Nodes;
using Hermes.Core.Attachments;
using Hermes.Core.Model;

namespace Hermes.Core.Chat;

/// Stored rows → bubbles (HermesKit/Chat/Hydration.swift, spec 03 §6.3). One message per user row and one assistant
/// message per turn: assistant rows with tool calls and the tool rows after them fold into the turn's bubble, parts in
/// row order. Rows are ordered by id, never by timestamp.
public static class HistoryFold
{
    private static readonly HashSet<string> NoticeKinds =
        ["auto_continue", "personality_switch", "async_delegation_complete", "process_complete", "failed_turn"];

    public static List<ChatMessage> Fold(IEnumerable<JsonNode?> rows, int pageSeq = 0)
    {
        var output = new List<ChatMessage>();
        List<ChatPart>? turn = null;
        string? turnId = null;
        long? turnRow = null;
        DateTimeOffset? turnTime = null;
        var generatedArgs = new Dictionary<string, JsonNode?>(); // image_generate calls' arguments, by call id

        IReadOnlyList<Hermes.Core.Transcripts.MessageReaction> turnReactions = [];
        long? turnWordsRow = null;

        void Flush()
        {
            if (turn is { Count: > 0 })
                output.Add(new ChatMessage(turnId!, Role.Assistant, SealTools(turn), turnTime, turnRow,
                    Reactions: turnReactions.Count > 0 ? turnReactions : null, ReactionRow: turnWordsRow));
            turn = null; turnId = null; turnRow = null; turnTime = null; turnReactions = []; turnWordsRow = null;
        }

        var index = 0;
        foreach (var row in rows)
        {
            var i = index++;
            if (row is not JsonObject r) continue;
            var kind = r.Str("display_kind");
            if (kind == "hidden") continue;
            var role = r.Str("role");
            var rowId = r.Int("row_id") ?? r.Int("id");
            var time = r.UnixTime("timestamp");
            string Id(string k) => rowId is { } id ? $"stored-row-{id}-{k}" : $"history-page-{pageSeq}-{i}-{k}";

            if (kind == "model_switch" || (kind != null && NoticeKinds.Contains(kind)) || role == "system")
            {
                Flush();
                var text = kind == "model_switch" ? "Model changed" : RowText(r);
                if (text.Length > 0) output.Add(new ChatMessage(Id("system"), Role.System, [new TextPart(text)], time, rowId));
                continue;
            }
            switch (role)
            {
                case "user":
                    Flush();
                    var mine = Hermes.Core.Transcripts.MessageReactions.FromRow(r);
                    output.Add(new ChatMessage(Id("user"), Role.User, AttachmentHydration.UserParts(RowText(r), r.Get("content")),
                        time, rowId, Reactions: mine.Count > 0 ? mine : null, ReactionRow: rowId));
                    break;
                case "assistant":
                    if (turn == null) { turn = []; turnId = Id("assistant"); turnRow = rowId; turnTime = time; }
                    if (Reasoning(r) is { } reasoning) turn.Add(new ReasoningPart(reasoning));
                    var answer = RowText(r);
                    if (answer.Length > 0) { turn.AddRange(AttachmentHydration.ReplyParts(answer)); turnWordsRow = rowId ?? turnWordsRow; }
                    turnReactions = Hermes.Core.Transcripts.MessageReactions.Merge(turnReactions,
                        Hermes.Core.Transcripts.MessageReactions.FromRow(r));
                    var calls = r.Arr("tool_calls") ?? [];
                    for (var c = 0; c < calls.Count; c++)
                    {
                        var call = calls[c];
                        var fn = call.Obj("function");
                        var id = call.Text("id") ?? call.Text("tool_call_id") ?? $"stored-tool-{c}";
                        if (turn.OfType<ToolPart>().Any(t => t.Call.Id == id)) id = $"{id}-{turnId}-{c}";
                        var name = call.Text("name") ?? call.Text("tool_name") ?? fn.Text("name") ?? "tool";
                        var rawArgs = fn?.Get("arguments") ?? call.Get("arguments") ?? call.Get("args") ?? call.Get("input");
                        if (name == GeneratedImages.ToolName) generatedArgs[id] = fn?.Get("arguments") ?? call.Get("arguments");
                        turn.Add(new ToolPart(new ToolCall(id, name, ArgsText(rawArgs), null, ToolState.Running,
                            ArgsJson: ArgsJson(rawArgs))));
                    }
                    break;
                case "tool":
                    if (turn == null) { turn = []; turnId = Id("tools"); turnRow = rowId; turnTime = time; }
                    PairResult(turn, r);
                    GeneratedImages.Apply(turn, r, generatedArgs);
                    break;
            }
        }
        Flush();
        return output;
    }

    /// display_content ?? content || text || context || name. Parts arrays join their text parts.
    public static string RowText(JsonObject r)
    {
        var v = r.Get("display_content") ?? r.Get("content");
        var s = Coerce(v);
        if (s.Length == 0) s = r.Text("text") ?? r.Text("context") ?? "";
        return s.Trim();
    }

    public static string Coerce(JsonNode? v) => v switch
    {
        JsonArray a => string.Concat(a.Select(p => p is JsonObject o ? o.Str("text") ?? o.Str("output_text") ?? "" : J.AsString(p) ?? "")),
        JsonObject o => o.Str("text") ?? o.Str("output_text") ?? "",
        _ => J.AsString(v) ?? "",
    };

    private static string? Reasoning(JsonObject r) =>
        r.Text("display_reasoning") ?? r.Text("reasoning") ?? r.Text("reasoning_content");

    private static void PairResult(List<ChatPart> turn, JsonObject r)
    {
        var callId = r.Text("tool_call_id");
        var name = r.Text("tool_name") ?? r.Text("name");
        for (var i = 0; i < turn.Count; i++)
        {
            if (turn[i] is not ToolPart { Call: { State: ToolState.Running } call }) continue;
            if (callId != null ? call.Id != callId : name != null && call.Name != name) continue;
            var content = Coerce(r.Get("content"));
            turn[i] = new ToolPart(call with { State = ToolState.Done, Summary = Summary(content), ResultText = Bounded(content) });
            return;
        }
    }

    /// Tool calls still open at the end of history are settled "Result unavailable".
    private static List<ChatPart> SealTools(List<ChatPart> parts) => [.. parts.Select(p =>
        p is ToolPart { Call.State: ToolState.Running } t
            ? new ToolPart(t.Call with { State = ToolState.Done, Summary = t.Call.Summary ?? "Result unavailable" }) : p)];

    /// Arguments arrive as a JSON string, an object, or text. Show the most telling value: command, path, query, url.
    public static string? ArgsText(JsonNode? args)
    {
        var node = args is JsonValue v && v.TryGetValue(out string? s) ? J.Parse(s) ?? args : args;
        if (node is JsonObject o)
        {
            foreach (var key in new[] { "command", "cmd", "path", "file_path", "query", "url", "pattern", "code" })
                if (o.Text(key) is { } val) return val;
            return o.Count == 0 ? null : o.ToJsonString(new JsonSerializerOptions { WriteIndented = false });
        }
        return J.AsString(node)?.Trim() is { Length: > 0 } t ? t : null;
    }

    /// The arguments as JSON text, the way HermesKit's ToolCall.argsText keeps them: a JSON string's own text, an
    /// object's JSON. The step wording (RunSummary) reads its keys.
    public static string? ArgsJson(JsonNode? args) => args switch
    {
        null => null,
        JsonValue v when v.TryGetValue(out string? s) => s.Length > 0 ? s : null,
        _ => args.ToJsonString(),
    };

    /// A result kept for the step sheet: at most 64 KB (the sheet shows the head of a big output).
    public static string? Bounded(string? text) =>
        string.IsNullOrEmpty(text) ? null : text.Length > 65_536 ? text[..65_536] : text;

    /// A short line for a finished tool: stdout's first line, an error, or the text's first line.
    public static string? Summary(string? result)
    {
        if (string.IsNullOrWhiteSpace(result)) return null;
        var j = J.Parse(result);
        var text = j is JsonObject o
            ? o.Text("error") ?? o.Text("output") ?? o.Text("stdout") ?? o.Text("result") ?? o.Text("content") ?? result
            : result;
        return ToolCall.FirstLine(text, 120);
    }
}
