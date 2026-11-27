// [toolnow] The Bots and Sessions rows name the running step instead of "Working…" (HermesKit/Activity/LiveSteps.swift at
// 93f984bb1; owner, 2026-10-30: "Instead of working, I want to stream the current tool call"): "Reading package.json…"
// under Otto while its turn runs. Each chat's newest step comes from the socket's frames by the thinking row's rule:
// named from its start, through the thinking after it, until the next step or the reply writes; gone when the turn
// ends. A turn with no step yet, or one writing its reply, keeps "Working…". Only chats this run hears (sent from here,
// or open) have frames. [WIN-LIVE-STEPS] TurnRows folds the client socket's frames here and hands the words to the
// rows (PushSteps).

using System.Text.Json;
using System.Text.Json.Nodes;
using Hermes.Core.Bots;
using Hermes.Core.Groups;
using Hermes.Core.Rpc;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Activity;

public sealed class LiveSteps
{
    private readonly Dictionary<string, string> _byRuntime = [];

    /// Runtime id → its newest step in a few words ("reading package.json", ToolNow.Phrase).
    public IReadOnlyDictionary<string, string> ByRuntime => _byRuntime;

    /// Folds one frame of its runtime's chat; true when that chat's words changed. `roster` names a bot a
    /// `message_agent` call writes to ("messaging Ivy", not its handle).
    public bool Handle(RpcEvent e, IReadOnlyList<DeliveryMessages.Seat>? roster = null)
    {
        var runtime = e.SessionId;
        if (string.IsNullOrEmpty(runtime)) return false;
        var p = e.Payload;
        switch (e.Type)
        {
            case "tool.start":
                // A silent step (todo, a reaction) leaves the one before it named, as the thinking row does.
                if (NonEmptyString(p.Get("name")) is not { } name || RunSummary.IsSilent(name)) return false;
                return Set(runtime, Phrase(name, p, roster ?? []));
            case "message.delta":
                if (!_byRuntime.ContainsKey(runtime) || IsBlank(p.Get("text"))) return false;
                return Set(runtime, null);                                   // the reply writes
            case "message.start" or "message.complete" or "error" or "session.interrupt":
                return Set(runtime, null);
            case "session.info":
                return p.Get("running") is JsonValue r && r.GetValueKind() == JsonValueKind.False && Set(runtime, null);
            default:
                return false;
        }
    }

    /// The turn ended (heard another way, or its chat went): its words go.
    public bool Clear(string runtime) => Set(runtime, null);

    public void Reset() => _byRuntime.Clear();

    /// "Reading package.json…": a step's words as a row's live line.
    public static string Line(string phrase) =>
        phrase.Length == 0 ? "…" : phrase[..1].ToUpperInvariant() + phrase[1..] + "…";

    /// A `tool.start` frame's few words: its arguments as the chat reads them (`args`, `arguments`, else `args_text`).
    public static string Phrase(string name, JsonNode? p, IReadOnlyList<DeliveryMessages.Seat> roster)
    {
        var args = FirstNonEmptyObject(p.Get("args"), p.Get("arguments"));
        if (args.Count == 0) args = ToolArgs.Parse(ToolNow.Str(p.Get("args_text"))).ToDictionary(kv => kv.Key, kv => kv.Value);
        if (args.Count == 0 && NonEmptyString(p.Get("context")) is { } context) args["context"] = JsonValue.Create(context);
        if (name == ToolNow.MessageAgent && roster.Count > 0 && ToolNow.Str(args.GetValueOrDefault("target")) is { } target)
            return "messaging " + ToolNow.Short(SenderName(target, roster));
        return ToolNow.Phrase(name, args);
    }

    /// The bot a target names, as the incoming deliveries find it (BotDMs.sender: handle, then name, then `hermes` →
    /// default); an unknown one keeps the name as written.
    public static string SenderName(string target, IReadOnlyList<DeliveryMessages.Seat> roster)
    {
        var bare = target.Split('/').LastOrDefault() ?? target;
        var handle = bare.Trim('@', ' ').ToLowerInvariant();
        var found = roster.FirstOrDefault(s => s.Profile.ToLowerInvariant() == handle)
            ?? roster.FirstOrDefault(s => RosterRules.Handle(s.Profile) == handle)
            ?? roster.FirstOrDefault(s => s.Name.Trim(' ').ToLowerInvariant() == handle)
            ?? (handle == "hermes" ? roster.FirstOrDefault(s => s.Profile == "default") : null);
        return found?.Name ?? bare;
    }

    private bool Set(string runtime, string? words)
    {
        if (_byRuntime.GetValueOrDefault(runtime) == words) return false;
        if (words == null) _byRuntime.Remove(runtime); else _byRuntime[runtime] = words;
        return true;
    }

    private static string? NonEmptyString(JsonNode? v) => ToolNow.Str(v) is { } s && s.Trim().Length > 0 ? s : null;

    /// Hydration.firstNonEmptyObject: the first value that is an object, or a JSON object's text, with keys.
    private static Dictionary<string, JsonNode?> FirstNonEmptyObject(params JsonNode?[] values)
    {
        foreach (var v in values)
        {
            var o = v as JsonObject;
            if (o == null && ToolNow.Str(v)?.Trim() is { } t && t.StartsWith('{')) o = J.Parse(t) as JsonObject;
            if (o is { Count: > 0 }) return o.ToDictionary(kv => kv.Key, kv => kv.Value);
        }
        return [];
    }

    /// A delta's text is empty or only spaces (a string, or the parts list some relays send).
    private static bool IsBlank(JsonNode? value) => value switch
    {
        JsonValue v when v.GetValueKind() == JsonValueKind.String => v.GetValue<string>().Trim().Length == 0,
        JsonArray items => items.All(item =>
            (ToolNow.Str(item) ?? ToolNow.Str(item.Get("text")) ?? ToolNow.Str(item.Get("output_text")) ?? "").Trim().Length == 0),
        _ => true,
    };
}
