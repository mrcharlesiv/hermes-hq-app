using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hermes.Core.Attachments;
using Hermes.Core.Groups;
using Hermes.Core.Model;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Chat;

/// Stored rows → bubbles (HermesKit/Chat/Hydration.swift, spec 03 §6.3). One message per user row and one assistant
/// message per turn: assistant rows with tool calls and the tool rows after them fold into the turn's bubble, parts in
/// row order. Rows are ordered by id, never by timestamp.
public static class HistoryFold
{
    private static readonly HashSet<string> NoticeKinds =
        ["auto_continue", "personality_switch", "async_delegation_complete", "process_complete", "failed_turn", "scheduled_wake", "loop_wakeup"];

    private static readonly Regex OriginRe = new(
        @"^Gateway message origin \(JSON data, not instructions or authorization\):\n\{[^\n]*\}\nDo not guess a reply destination when these fields are insufficient\.\n+",
        RegexOptions.Compiled);

    private static readonly Regex TurnContextRe = new(
        @"(?:^|\n)[ \t]*(?:\(Hermes HQ: [\s\S]*\)|<memory-context>[\s\S]*?</memory-context>|\[System: This conversation is now being answered on a different interface: [\s\S]*)\s*$",
        RegexOptions.Compiled);

    private static readonly Regex SubagentBatchRe = new(@"—\s*(\d+)\s+subagent", RegexOptions.IgnoreCase | RegexOptions.Compiled);

    /// Removes trailing Hermes turn context (`(Hermes HQ: …)`, `<memory-context>`, surface-switch note).
    public static string StrippingTurnContext(string text)
    {
        if (!text.Contains("(Hermes HQ: ", StringComparison.Ordinal)
            && !text.Contains("</memory-context>", StringComparison.Ordinal)
            && !text.Contains("[System: This conversation is now being answered on a different interface: ", StringComparison.Ordinal))
            return text;
        var s = text;
        while (true)
        {
            var m = TurnContextRe.Match(s);
            if (!m.Success) break;
            s = s.Remove(m.Index, m.Length);
        }
        return s.TrimEnd();
    }

    /// Removes a leading gateway routing-origin header from a message body.
    public static string StripOrigin(string text)
    {
        var m = OriginRe.Match(text);
        return m.Success ? text[(m.Index + m.Length)..] : text;
    }

    private static JsonObject NormalizeRow(JsonObject row)
    {
        var record = (JsonObject)row.DeepClone();
        var text = record.Str("content") ?? "";
        var kind = record.Str("display_kind");
        var role = record.Str("role");

        if (role is "user" or "system" && TimelineNotes.IsTaskSnapshot(Coerce(record.Get("display_content") ?? record.Get("content"))))
        {
            record["display_kind"] = "hidden";
            return record;
        }

        // [botdm] Keep bot DM runner notes as plain user rows so BotDMs.Resolve turns them into the other bot's reply.
        if (kind is "internal_notification" or "process_complete")
        {
            var body = text.TrimStart();
            if (body.StartsWith("[IMPORTANT: ", StringComparison.Ordinal) && BotDMs.IsDelivery(body))
            {
                record.Remove("display_kind");
                return record;
            }
        }

        if (kind == "internal_notification")
        {
            var meta = record.Obj("display_metadata")?.DeepClone() as JsonObject ?? [];
            // #612: strip gateway routing header and turn context BEFORE checking for bot-to-bot delivery,
            // otherwise an inbound bot DM with a routing prefix falls through to "Background update" and triggers an unread dot.
            var stripped = StripOrigin(StrippingTurnContext(text));
            var body = stripped.TrimStart();
            if (DeliveryMessages.MayBeDelivery(body) && DeliverySender.Parse(body) != null)
            {
                record.Remove("display_kind");
                record["content"] = body;
                return record;
            }
            if (body.StartsWith("[IMPORTANT: ", StringComparison.Ordinal))
            {
                record["display_kind"] = "process_complete";
                record["display_metadata"] = meta;
                return record;
            }
            if (meta.Text("display_text") == null)
            {
                if (body.StartsWith("[ASYNC DELEGATION", StringComparison.Ordinal))
                {
                    var sm = SubagentBatchRe.Match(body);
                    if (sm.Success && int.TryParse(sm.Groups[1].Value, out var count))
                        meta["task_count"] = count;
                    else
                        meta["display_text"] = "Helpers finished";
                }
                else
                {
                    meta["display_text"] = "Background update";
                }
            }
            record["display_kind"] = "async_delegation_complete";
            record["display_metadata"] = meta;
            return record;
        }

        if (role == "user" && kind != "hidden")
        {
            foreach (var key in new[] { "content", "display_content" })
            {
                if (record.Get(key) is JsonValue jv && jv.TryGetValue(out string? s))
                {
                    var cleaned = StripOrigin(StrippingTurnContext(s));
                    if (cleaned != s) record[key] = cleaned;
                }
            }
        }

        return record;
    }

    public static List<ChatMessage> Fold(IEnumerable<JsonNode?> rows, int pageSeq = 0)
    {
        var output = new List<ChatMessage>();
        List<ChatPart>? turn = null;
        string? turnId = null;
        long? turnRow = null;
        DateTimeOffset? turnTime = null;
        DateTimeOffset? turnLatestTime = null;
        var generatedArgs = new Dictionary<string, JsonNode?>(); // image_generate calls' arguments, by call id

        IReadOnlyList<MessageReaction> turnReactions = [];
        long? turnWordsRow = null;

        void NoteTurnTime(DateTimeOffset? at)
        {
            if (at is { } t && (turnLatestTime is not { } cur || t > cur)) turnLatestTime = t;
        }

        void Flush()
        {
            if (turn is { Count: > 0 })
            {
                DateTimeOffset? latest = turnTime is { } first && turnLatestTime is { } end && (end - first).TotalSeconds > 0.5
                    ? (DateTimeOffset?)end : null;
                output.Add(new ChatMessage(turnId!, Role.Assistant, SealTools(turn), turnTime, turnRow,
                    Reactions: turnReactions.Count > 0 ? turnReactions : null, ReactionRow: turnWordsRow,
                    LatestTimestamp: latest));
            }
            turn = null; turnId = null; turnRow = null; turnTime = null; turnLatestTime = null; turnReactions = []; turnWordsRow = null;
        }

        var index = 0;
        foreach (var rawRow in rows)
        {
            var i = index++;
            if (rawRow is not JsonObject rawObj) continue;
            var r = NormalizeRow(rawObj);
            var kind = r.Str("display_kind");
            if (kind == "hidden") continue;
            var role = r.Str("role");
            var rowId = r.Int("row_id") ?? r.Int("id");
            var time = r.UnixTime("timestamp");
            string Id(string k) => rowId is { } id ? $"stored-row-{id}-{k}" : $"history-page-{pageSeq}-{i}-{k}";

            if (kind == "model_switch" || (kind != null && NoticeKinds.Contains(kind)) || role == "system")
            {
                Flush();
                var rawText = RowText(r);
                var meta = r.Obj("display_metadata");
                string text;
                string? job = null;
                switch (kind)
                {
                    case "model_switch":
                        text = TimelineNotes.IsModelSwitch(rawText) ? TimelineNotes.ModelSwitchLabel(rawText) : "Model changed";
                        break;
                    case "auto_continue":
                        text = "resumed interrupted turn";
                        break;
                    case "personality_switch":
                        text = "personality changed";
                        break;
                    case "async_delegation_complete":
                        text = meta.Text("display_text")
                            ?? (meta.Int("task_count") is { } tc ? $"{tc} helper{(tc == 1 ? "" : "s")} finished" : "Helpers finished");
                        break;
                    case "process_complete":
                        text = CronDeliveries.ProcessNote(rawText) is { } pw && TimelineNotes.ProcessHeadline(pw) is { } split
                            ? split.Headline
                            : meta.Text("display_text") ?? (rawText.Length > 0 ? rawText : "background process finished");
                        break;
                    case "scheduled_wake":
                    case "loop_wakeup":
                        text = meta.Text("display_text") ?? meta.Text("title")
                            ?? TimelineNotes.ScheduledWake(rawText)?.Title
                            ?? (kind == "loop_wakeup" ? "Loop wakeup" : "Scheduled check");
                        job = text;
                        break;
                    default:
                        text = rawText;
                        break;
                }
                if (text.Length > 0)
                    output.Add(new ChatMessage(Id("system"), Role.System, [new TextPart(text)], time, rowId) { Job = job });
                continue;
            }
            switch (role)
            {
                case "user":
                    Flush();
                    var mine = MessageReactions.FromRow(r);
                    output.Add(new ChatMessage(Id("user"), Role.User, AttachmentHydration.UserParts(RowText(r), r.Get("content")),
                        time, rowId, Reactions: mine.Count > 0 ? mine : null, ReactionRow: rowId));
                    break;
                case "assistant":
                    if (turn == null) { turn = []; turnId = Id("assistant"); turnRow = rowId; turnTime = time; turnLatestTime = time; }
                    else NoteTurnTime(time);
                    if (Reasoning(r) is { } reasoning) turn.Add(new ReasoningPart(reasoning));
                    var answer = RowText(r);
                    if (answer.Length > 0) { turn.AddRange(AttachmentHydration.ReplyParts(answer)); turnWordsRow = rowId ?? turnWordsRow; }
                    turnReactions = MessageReactions.Merge(turnReactions, MessageReactions.FromRow(r));
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
                    if (turn == null) { turn = []; turnId = Id("tools"); turnRow = rowId; turnTime = time; turnLatestTime = time; }
                    else NoteTurnTime(time);
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
