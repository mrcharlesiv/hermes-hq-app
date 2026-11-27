using System.Text.Json.Nodes;
using Hermes.Core.Net;
using Hermes.Core.Rpc;

namespace Hermes.Core.Questions;

/// What the question centre needs from the account (HermesKit `GatewayClient` + `ServerRequestAnswering`), so tests
/// can stand in for the socket.
public interface IQuestionTransport
{
    Task<JsonNode> CallAsync(string method, JsonObject parameters, TimeSpan timeout);
    /// Answer a server→client request on the current socket; returns that socket's epoch. Throws
    /// GatewayException("offline") when no socket is up or the send failed.
    Task<int> RespondAsync(string id, JsonNode result);
    Task<int> FailAsync(string id, int code, string message);
    bool DeclinesNotShown { get; }
    bool Connected { get; }
    /// `GET /api/config[?profile=]` (only `approvals.timeout` is read).
    Task<JsonNode?> ConfigAsync(string? profile);
    void ReconnectNow();
}

/// The live transport: the account's socket and REST session.
public sealed class RpcQuestionTransport(RpcConnection rpc, GatewaySession session) : IQuestionTransport
{
    public Task<JsonNode> CallAsync(string method, JsonObject parameters, TimeSpan timeout) =>
        rpc.RequestAsync(method, parameters, timeout);

    public Task<int> RespondAsync(string id, JsonNode result) => rpc.RespondAsync(id, result);
    public Task<int> FailAsync(string id, int code, string message) => rpc.FailAsync(id, code, message);
    public bool DeclinesNotShown => rpc.DeclinesNotShown;
    public bool Connected => rpc.State == ConnectionState.Open;

    public async Task<JsonNode?> ConfigAsync(string? profile)
    {
        var query = profile == null ? null : new[] { new KeyValuePair<string, string>("profile", profile) };
        try { return await session.GetJsonAsync("/api/config", query); }
        catch (GatewayException) { return null; }
    }

    public void ReconnectNow() => rpc.ReconnectNow();
}
