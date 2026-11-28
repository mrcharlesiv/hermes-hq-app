using System.Reflection;
using System.Text.Json.Nodes;

namespace Hermes.Core.Rpc;

/// Client identity announced on `client.capabilities {"client": ...}` (`CanonicalClientIdentity`, Hermes 0.23.4+).
public sealed record ClientIdentity(string Name, string Kind, string? Version)
{
    public static ClientIdentity Current()
    {
        var version = Assembly.GetExecutingAssembly().GetName().Version?.ToString(3);
        return new ClientIdentity("hermes-hq-windows", "desktop", SanitizedVersion(version));
    }

    public static string? SanitizedVersion(string? raw)
    {
        var trimmed = raw?.Trim() ?? "";
        if (trimmed.Length == 0 || trimmed.Length > 64) return null;
        return trimmed.All(c => c is >= (char)0x21 and <= (char)0x7E) ? trimmed : null;
    }

    public JsonObject ToJson()
    {
        var o = new JsonObject
        {
            ["name"] = Name,
            ["kind"] = Kind,
        };
        if (Version != null) o["version"] = Version;
        return o;
    }
}

public enum ClientActivityBasis { System, Page }

/// Presence report sent via `client.activity` (`ClientActivityParams`, Hermes 0.23.4+) when the gateway advertises
/// `client_activity: true` on `client.capabilities`.
public sealed record ClientActivityReport(
    IReadOnlyList<string> Sessions,
    double IdleSeconds,
    ClientActivityBasis Basis = ClientActivityBasis.Page,
    bool CanAlert = true,
    bool Away = false)
{
    public JsonObject ToJson()
    {
        var bounded = new JsonArray();
        foreach (var s in Sessions.Where(s => !string.IsNullOrEmpty(s) && s.Length <= 256).Take(16))
            bounded.Add(s);
        return new JsonObject
        {
            ["sessions"] = bounded,
            ["idle_seconds"] = Math.Max(0, double.IsFinite(IdleSeconds) ? IdleSeconds : 0),
            ["basis"] = Basis == ClientActivityBasis.System ? "system" : "page",
            ["can_alert"] = CanAlert,
            ["away"] = Away,
        };
    }
}
