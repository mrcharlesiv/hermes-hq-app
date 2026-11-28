using System.Security.Cryptography;
using System.Text.Json.Nodes;
using Hermes.Core.Capabilities;

namespace Hermes.Core.Composio;

// Port of HermesKit/Composio/ComposioGateway.swift (docs/spec/3x-capabilities.md §10.6):
// One shared record in `ui_meta["dispatch-composio"]` on the `default` profile, and per bot an MCP server named
// `composio` referencing `${COMPOSIO_API_KEY}` plus the key stored in that bot's env via `PUT /api/env`.

public sealed record ComposioRecord(string UserId, string SessionId, bool AllBots)
{
    public const string Key = "dispatch-composio";
    public const string Server = "composio";
    public const string EnvKey = "COMPOSIO_API_KEY";

    public static string NewUserId() =>
        "dispatch-" + Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(6));

    public static ComposioRecord? Read(JsonNode? value)
    {
        if (value == null || value.Text("userId") is not { } user) return null;
        return new ComposioRecord(
            UserId: user,
            SessionId: value.Str("sessionId") ?? "",
            AllBots: value.Bool("allBots") ?? false);
    }

    public JsonObject ToJson() => new()
    {
        ["userId"] = UserId,
        ["sessionId"] = SessionId,
        ["allBots"] = AllBots,
    };

    /// The MCP server config a bot gets: the session's MCP URL and literal `${COMPOSIO_API_KEY}` reference, never the key.
    public static JsonObject Entry(string mcpUrl) => new()
    {
        ["url"] = mcpUrl,
        ["headers"] = new JsonObject { ["x-api-key"] = "${COMPOSIO_API_KEY}" },
    };
}

/// Transport seam behind `ComposioGateway` so gateway flows can be exercised cleanly in unit tests as well as live over `CapabilitiesApi`.
public interface IComposioGatewayTransport
{
    bool ReadOnly { get; }
    Task<JsonNode> CallRpcAsync(string method, JsonObject parameters, TimeSpan timeout, CancellationToken ct = default);
    Task<List<McpServer>> McpServersAsync(string profile, CancellationToken ct = default);
    Task SetEnvAsync(string key, string value, string profile, CancellationToken ct = default);
    Task DeleteEnvAsync(string key, string profile, CancellationToken ct = default);
    Task<string?> RevealEnvAsync(string key, string profile, CancellationToken ct = default);
    Task McpAddAsync(string name, JsonObject config, string? bearer, string profile, CancellationToken ct = default);
    Task McpRemoveAsync(string name, string profile, CancellationToken ct = default);
    Task ReloadMcpAsync(CancellationToken ct = default);
}

/// Live transport delegating directly to `CapabilitiesApi` (using Wave 5B's `RevealEnvAsync` contract).
public sealed class CapabilitiesComposioTransport(CapabilitiesApi api) : IComposioGatewayTransport
{
    public bool ReadOnly => api.ReadOnly;

    public Task<JsonNode> CallRpcAsync(string method, JsonObject parameters, TimeSpan timeout, CancellationToken ct = default) =>
        api.Rpc.RequestAsync(method, parameters, timeout, ct);

    public Task<List<McpServer>> McpServersAsync(string profile, CancellationToken ct = default) =>
        api.McpServersAsync(profile, ct);

    public Task SetEnvAsync(string key, string value, string profile, CancellationToken ct = default) =>
        api.SetEnvAsync(key, value, profile);

    public Task DeleteEnvAsync(string key, string profile, CancellationToken ct = default) =>
        api.DeleteEnvAsync(key, profile);

    public Task<string?> RevealEnvAsync(string key, string profile, CancellationToken ct = default) =>
        api.RevealEnvAsync(key, profile, ct);

    public Task McpAddAsync(string name, JsonObject config, string? bearer, string profile, CancellationToken ct = default) =>
        api.McpAddAsync(name, config, bearer, profile);

    public Task McpRemoveAsync(string name, string profile, CancellationToken ct = default) =>
        api.McpRemoveAsync(name, profile);

    public async Task ReloadMcpAsync(CancellationToken ct = default) =>
        await api.ReloadMcpAsync().ConfigureAwait(false);
}

/// Reads and writes Connect Apps' shared gateway record and per-bot `composio` MCP server / env key.
public sealed class ComposioGateway(IComposioGatewayTransport transport)
{
    public ComposioGateway(CapabilitiesApi api) : this(new CapabilitiesComposioTransport(api)) { }

    public bool ReadOnly => transport.ReadOnly;

    /// Reads the shared `ui_meta["dispatch-composio"]` record from the `default` profile via `profiles.list`.
    public async Task<ComposioRecord?> RecordAsync(CancellationToken ct = default)
    {
        var value = await transport.CallRpcAsync("profiles.list", new JsonObject { ["include_sessions"] = false },
            TimeSpan.FromSeconds(30), ct).ConfigureAwait(false);
        var rows = value.Arr("profiles") ?? (value as JsonArray);
        if (rows == null) return null;
        var row = rows.FirstOrDefault(r => r.Text("name") == "default");
        return ComposioRecord.Read(row.Obj("ui_meta").Get(ComposioRecord.Key));
    }

    /// Writes (or clears when `record == null`) `ui_meta["dispatch-composio"]` on the `default` profile via `profiles.configure`.
    public async Task WriteAsync(ComposioRecord? record, CancellationToken ct = default)
    {
        if (ReadOnly) throw new CapabilityException("", CapabilityException.ReadOnlyReason);
        var uiMeta = new JsonObject { [ComposioRecord.Key] = record?.ToJson() };
        var value = await transport.CallRpcAsync("profiles.configure", new JsonObject
        {
            ["name"] = "default",
            ["ui_meta"] = uiMeta,
        }, TimeSpan.FromSeconds(30), ct).ConfigureAwait(false);
        if (value.Obj("applied").Bool("ui_meta") != true)
            throw new CapabilityException("", "This gateway couldn’t save the Composio setting.");
    }

    /// Returns the bot's `composio` MCP server if configured.
    public async Task<McpServer?> ServerAsync(string profile, CancellationToken ct = default)
    {
        var servers = await transport.McpServersAsync(profile, ct).ConfigureAwait(false);
        return servers.FirstOrDefault(s => s.Name == ComposioRecord.Server);
    }

    /// Enables Composio for a bot: saves `COMPOSIO_API_KEY` via `PUT /api/env`, replaces the `composio` MCP server with
    /// `${COMPOSIO_API_KEY}` header reference, and reloads MCP.
    public async Task TurnOnAsync(string profile, string key, string mcpUrl, CancellationToken ct = default)
    {
        if (ReadOnly) throw new CapabilityException("", CapabilityException.ReadOnlyReason);
        await transport.SetEnvAsync(ComposioRecord.EnvKey, key, profile, ct).ConfigureAwait(false);
        await transport.McpRemoveAsync(ComposioRecord.Server, profile, ct).ConfigureAwait(false);
        await transport.McpAddAsync(ComposioRecord.Server, ComposioRecord.Entry(mcpUrl), null, profile, ct).ConfigureAwait(false);
        await transport.ReloadMcpAsync(ct).ConfigureAwait(false);
    }

    /// Disables Composio for a bot: removes the `composio` MCP server, deletes `COMPOSIO_API_KEY`, and reloads MCP.
    /// Connected accounts stay in the user's Composio project.
    public async Task TurnOffAsync(string profile, CancellationToken ct = default)
    {
        if (ReadOnly) throw new CapabilityException("", CapabilityException.ReadOnlyReason);
        await transport.McpRemoveAsync(ComposioRecord.Server, profile, ct).ConfigureAwait(false);
        await transport.DeleteEnvAsync(ComposioRecord.EnvKey, profile, ct).ConfigureAwait(false);
        await transport.ReloadMcpAsync(ct).ConfigureAwait(false);
    }

    /// Reveals `COMPOSIO_API_KEY` already held by a bot on this gateway (explicit user action only; DECISION 10.4-a).
    public Task<string?> RevealKeyAsync(string profile, CancellationToken ct = default) =>
        transport.RevealEnvAsync(ComposioRecord.EnvKey, profile, ct);
}
