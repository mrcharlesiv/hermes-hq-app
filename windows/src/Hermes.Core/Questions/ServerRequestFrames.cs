using System.Text.Json.Nodes;
using Hermes.Core.Rpc;

namespace Hermes.Core.Questions;

/// A server→client request (spec 1x §2.2): `{"jsonrpc":"2.0","id":"srq-…","method":"approval","params":{…}}`, live
/// or re-delivered from a result's `open_requests` (Replayed). Epoch is the socket it came on (HermesKit's
/// `LocalEvent.serverRequest` payload).
public sealed record ServerRequest(string Id, string Method, JsonObject Params, string SessionId, bool Replayed, int Epoch);

/// The authoritative open requests of one session (HermesKit `LocalEvent.openRequests`, spec 1x §2.4): the srq ids a
/// session.resume / session.activate / session.events.since result named, its `pending_approval`, and (a session
/// authority's snapshot only) the shared clarify prompt ids. A missing key in the result means none open.
public sealed record OpenRequests(string SessionId, IReadOnlyList<string> Ids, JsonObject? PendingApproval, string Method,
    int Epoch, IReadOnlyList<string>? PromptIds);

/// The answer frames (HermesKit/Net/RPCFrame+responses.swift): a JSON-RPC response with the request's string id and
/// `result` or `error`, never a `method` key.
public static class ServerRequestFrames
{
    public static JsonObject Response(string id, JsonNode result) => new()
    {
        ["jsonrpc"] = "2.0", ["id"] = id, ["result"] = result.DeepClone(),
    };

    public static JsonObject ErrorResponse(string id, int code, string message) => new()
    {
        ["jsonrpc"] = "2.0", ["id"] = id, ["error"] = new JsonObject { ["code"] = code, ["message"] = message },
    };
}

/// `open_requests` re-delivery (HermesKit `OpenRequestsIntercept`): what the connection raises, in order, before the
/// caller of a session.resume / session.activate / session.events.since sees its result. Pure, so it is unit-tested.
public static class OpenRequestsIntercept
{
    public static readonly IReadOnlySet<string> Methods =
        new HashSet<string> { "session.resume", "session.activate", "session.events.since" };

    /// One replayed ServerRequest per `open_requests` entry, a `clarify.request` RpcEvent per shared prompt (session
    /// authority), then one OpenRequests. A result that isn't an object yields nothing.
    public static IReadOnlyList<object> Events(string method, JsonObject parameters, JsonNode? result, int epoch)
    {
        if (!Methods.Contains(method) || result is not JsonObject) return [];
        var session = result.Text("session_id") ?? parameters.Str("session_id") ?? "";
        if (session.Length == 0) return [];
        var output = new List<object>();
        var ids = new List<string>();
        foreach (var item in result.Arr("open_requests") ?? [])
        {
            if (item.Str("id") is not { } id || item.Str("method") is not { } requestMethod) continue;
            var requestParams = item.Obj("params")?.DeepClone() as JsonObject ?? new JsonObject();
            var owner = requestParams.Str("session_id") ?? session;
            ids.Add(id);
            output.Add(new ServerRequest(id, requestMethod, requestParams, owner, true, epoch));
        }
        List<string>? promptIds = null;
        if (result.Arr("prompts") is { } prompts)
        {
            promptIds = [];
            foreach (var prompt in prompts)
            {
                if (prompt.Str("kind") != "clarify" || prompt.Text("prompt_id") is not { } promptId) continue;
                promptIds.Add(promptId);
                output.Add(new RpcEvent("clarify.request", session, prompt!.DeepClone(), null));
            }
        }
        var pending = result.Obj("pending_approval")?.DeepClone() as JsonObject;
        output.Add(new OpenRequests(session, ids, pending, method, epoch, promptIds));
        return output;
    }
}
