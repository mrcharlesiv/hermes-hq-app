using System.Text.Json.Nodes;

namespace Hermes.Core.Net;

/// [authority] A gateway-hosted Hermes (its own sign-in page, the browser Desktop, a Team Gateway) serves /api/ws from
/// its session authority: `gateway.ready` says `session_authority: true`, and it answers with a closed key set per verb
/// (HermesKit/Net/AuthorityWire.swift, 93f984bb1):
///   - `prompt.submit` needs a request id (`submission_id`); the plain sidecar refuses that key as unknown (4000), so it
///     goes out only here. A caller names its own (one per send, so a retry replays the same admission rather than
///     adding a second turn); one is made here otherwise.
///   - `session.redirect` / `session.interrupt` / `approval.respond` name the running turn (`execution_generation`,
///     from the session's frames and snapshots); `approval.respond` names its prompt `prompt_id`, with no
///     `request_id`/`all`.
///   - `session.activate` isn't served: `session.resume` takes the same params and answers the same snapshot.
///   - `session.create` takes the surface as `source: "gui"` (not "desktop"), a retry key as `request_id` (not
///     `idempotency_key`), and a room member's `room_plumbing` as `follow_profile_config`.
public static class AuthorityWire
{
    /// Verbs that name the running turn on an authority socket.
    public static readonly IReadOnlySet<string> TurnControls =
        new HashSet<string> { "session.redirect", "session.interrupt", "approval.respond" };

    /// The frame as this socket takes it: `generation` is the session's latest known turn (null when none was seen).
    /// The caller's object is never changed: an adapted frame is a copy.
    public static (string Method, JsonObject Params) Adapt(string method, JsonObject parameters, bool authority,
        long? generation = null)
    {
        if (!authority)
        {
            if (method == "prompt.submit" && parameters.ContainsKey("submission_id"))
            {
                var stripped = (JsonObject)parameters.DeepClone();
                stripped.Remove("submission_id");
                return (method, stripped);
            }
            return (method, parameters);
        }
        var o = (JsonObject)parameters.DeepClone();
        switch (method)
        {
            case "prompt.submit":
                if (!(o.Get("submission_id") is JsonValue sv && sv.TryGetValue(out string? s) && s.Length > 0))
                    o["submission_id"] = Guid.NewGuid().ToString("D");
                break;
            case "session.activate":
                return ("session.resume", parameters);
            case "session.create":
                if (o.Get("room_plumbing") is JsonValue rv && rv.GetValueKind() == System.Text.Json.JsonValueKind.True)
                    o["follow_profile_config"] = true;
                o.Remove("room_plumbing");
                if (o.Get("idempotency_key") is { } key)
                {
                    o.Remove("idempotency_key");
                    if (!o.ContainsKey("request_id")) o["request_id"] = key.DeepClone();
                }
                o["source"] = "gui";
                o.Remove("cols");   // a terminal width the create contract doesn't take
                // Anything else stays, so a create the owner can't do (a branch's copied `messages`) is refused, never made empty.
                break;
            case "approval.respond":
                if (!o.ContainsKey("prompt_id") && o.Get("request_id") is { } request) o["prompt_id"] = request.DeepClone();
                o.Remove("request_id");
                o.Remove("all");
                break;
        }
        if (TurnControls.Contains(method) && !o.ContainsKey("execution_generation") && generation is { } g)
            o["execution_generation"] = g;
        return (method, o);
    }

    /// The request id one send keeps through its retries.
    public static string SubmissionId(string localId) => "hq-" + localId;

    /// The turn an event frame's params name (`execution_generation`), or null; a bool is not a turn.
    public static long? Generation(JsonNode? eventParams) =>
        eventParams.Get("execution_generation") is JsonValue v && v.GetValueKind() == System.Text.Json.JsonValueKind.Number
        && double.TryParse(v.ToJsonString(), System.Globalization.NumberStyles.Float,
            System.Globalization.CultureInfo.InvariantCulture, out var d) ? (long)d : null;
}
