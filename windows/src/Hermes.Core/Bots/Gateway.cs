using System.Text.Json;
using System.Text.Json.Nodes;
using Hermes.Core.Net;

namespace Hermes.Core.Bots;

/// A REST answer the stores read (status and body only).
public sealed record RestAnswer(int Status, string Body)
{
    public JsonNode? Json => J.Parse(Body);
    public bool Ok => Status is >= 200 and < 300;
}

/// What the Bots and Sessions stores need from a signed-in gateway: JSON-RPC calls and REST. `HermesClient` supplies the
/// real one (`ClientGateway`); tests supply a fake.
public interface IListsGateway
{
    /// The account the device state is kept under.
    string AccountId { get; }
    Task<JsonNode> CallAsync(string method, JsonObject parameters, TimeSpan timeout, CancellationToken ct = default);
    Task<RestAnswer> RestAsync(HttpMethod method, string path, IEnumerable<KeyValuePair<string, string>>? query = null,
        JsonNode? body = null, CancellationToken ct = default);
}

public sealed class ClientGateway(HermesClient client) : IListsGateway
{
    public HermesClient Client { get; } = client;
    public string AccountId => Client.AccountId;

    public Task<JsonNode> CallAsync(string method, JsonObject parameters, TimeSpan timeout, CancellationToken ct = default) =>
        Client.Rpc.RequestAsync(method, parameters, timeout, ct);

    public async Task<RestAnswer> RestAsync(HttpMethod method, string path, IEnumerable<KeyValuePair<string, string>>? query = null,
        JsonNode? body = null, CancellationToken ct = default)
    {
        var a = await Client.Session.SendAsync(method, path, query, body, ct: ct);
        return new RestAnswer(a.Status, a.Body);
    }
}

/// Device-local state, by gateway account (the iPhone app's per-account device file). The app keeps it in
/// %LOCALAPPDATA%\HermesHQ\lists; tests keep it in memory.
public interface IDeviceStore
{
    string? Read(string key);
    void Write(string key, string? value);
}

public sealed class MemoryDeviceStore : IDeviceStore
{
    private readonly Dictionary<string, string> _values = [];
    public string? Read(string key) { lock (_values) return _values.GetValueOrDefault(key); }
    public void Write(string key, string? value)
    {
        lock (_values) { if (value == null) _values.Remove(key); else _values[key] = value; }
    }
}

/// One JSON file per key under a folder. Writes replace the file whole (write then move).
public sealed class FileDeviceStore(string root) : IDeviceStore
{
    private readonly object _gate = new();

    private string PathOf(string key)
    {
        var safe = string.Concat(key.Select(c => char.IsLetterOrDigit(c) || c is '-' or '_' or '.' ? c : '_'));
        return Path.Combine(root, safe + ".json");
    }

    public string? Read(string key)
    {
        try { lock (_gate) return File.Exists(PathOf(key)) ? File.ReadAllText(PathOf(key)) : null; }
        catch (IOException) { return null; }
    }

    public void Write(string key, string? value)
    {
        try
        {
            lock (_gate)
            {
                var path = PathOf(key);
                if (value == null) { File.Delete(path); return; }
                Directory.CreateDirectory(root);
                File.WriteAllText(path + ".tmp", value);
                File.Move(path + ".tmp", path, overwrite: true);
            }
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}

public static class DeviceJson
{
    public static readonly JsonSerializerOptions Options = new() { WriteIndented = false, PropertyNamingPolicy = JsonNamingPolicy.CamelCase };

    public static T Load<T>(IDeviceStore store, string key) where T : new()
    {
        if (store.Read(key) is not { } text) return new T();
        try { return JsonSerializer.Deserialize<T>(text, Options) ?? new T(); }
        catch (JsonException) { return new T(); }
    }

    public static void Save<T>(IDeviceStore store, string key, T value) => store.Write(key, JsonSerializer.Serialize(value, Options));
}

/// A refused write the UI shows as an alert: "Couldn’t Pin Ivy" and the reason (BotWriteError).
public sealed class BotWriteException(string title, string reason, string? detail = null) : Exception(reason)
{
    public string Title { get; } = title;
    public string Reason { get; } = reason;
    public string? Detail { get; } = detail;

    public const string ReadOnlyReason = "Changes are turned off for this gateway in this build.";
    public const string NotSavedReason = "Your gateway didn’t save the change.";
    public const string UnsupportedReason = "This gateway can’t save bot settings yet. Update Hermes on the computer running Hermes, then try again.";
    public const string NoAnswer = "Your gateway didn’t answer in time. Try again in a moment.";
    /// NoticeWriteWords.dropped (PresenceRules.swift at 93f984bb1): a write the link dropped under.
    public const string Dropped = "The connection dropped before the computer running Hermes answered.";

    /// The plain reason for any failure (BotWriteOutcome.reason).
    public static string ReasonOf(Exception e) => e switch
    {
        BotWriteException w => w.Reason,
        GatewayException { Code: "timeout" } => NoAnswer,
        GatewayException { IsConnectionLost: true } => Dropped,
        GatewayException { IsNotConnected: true } g => g.Message,
        GatewayException { Code: "rpc" } g when System.Text.RegularExpressions.Regex.IsMatch(g.Message,
            "unknown|unsupported|invalid param|method not found|-3260", System.Text.RegularExpressions.RegexOptions.IgnoreCase) => UnsupportedReason,
        GatewayException { Code: "rpc" } g when g.Message.Length > 0 => g.PlainReason,
        GatewayException g when g.Message.Length > 0 => g.Message,
        _ => NotSavedReason,
    };
}
