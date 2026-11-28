using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Hermes.Core.Net;

namespace Hermes.Core.Notifications;

/// Port of HermesKit/Push/PushPolicy.swift: gateway add-on (`hermes-hq-push`) capability flags, account owner hash,
/// delivery kind filtering, and Windows push/test-notification endpoint client.
public static class PushPolicy
{
    public const string PluginRoute = "/api/plugins/hermes-hq-push";
    public static readonly string[] KnownKinds = ["turnDone", "approval", "input"];

    /// SHA-256 hash of normalized gateway URL + username (matching HermesKit/Push/PushPolicy.swift `owner`).
    public static string Owner(string url, string username)
    {
        var normalized = url.Trim();
        if (Uri.TryCreate(normalized, UriKind.Absolute, out var uri))
        {
            var ub = new UriBuilder(uri)
            {
                Scheme = uri.Scheme.ToLowerInvariant(),
                Host = uri.Host.ToLowerInvariant(),
                UserName = "",
                Password = "",
                Query = "",
                Fragment = "",
            };
            ub.Path = ub.Path.TrimEnd('/');
            normalized = ub.Uri.GetComponents(UriComponents.SchemeAndServer | UriComponents.Path, UriFormat.Unescaped).TrimEnd('/');
        }
        var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new[] { normalized, username }));
        return Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
    }

    public static IReadOnlySet<string> Kinds(JsonObject? body)
    {
        if (body == null) return new HashSet<string>(["turnDone", "approval"]);
        if (body.TryGetPropertyValue("delivery", out var del) && del is null) return new HashSet<string>();
        if (body.Arr("kinds") is { } arr)
        {
            return arr.Select(n => n?.GetValue<string>())
                .Where(s => s != null && KnownKinds.Contains(s))
                .Select(s => s!)
                .ToHashSet(StringComparer.Ordinal);
        }
        return new HashSet<string>(["turnDone", "approval"]);
    }

    public static IReadOnlySet<string> EnabledKinds(JsonObject? body, IReadOnlyDictionary<string, bool> prefs) =>
        Kinds(body).Where(k => !prefs.TryGetValue(k, out var on) || on).ToHashSet(StringComparer.Ordinal);

    public static bool Delivers(string eventKind, IReadOnlySet<string> kinds)
    {
        var mapped = eventKind switch
        {
            "message.complete" => "turnDone",
            "approval.request" => "approval",
            _ => eventKind,
        };
        return kinds.Contains(mapped);
    }

    public static bool Seals(JsonObject? body) => body?.Bool("seal") == true;
    public static bool Tasks(JsonObject? body) => body?.Bool("tasks") == true;
    public static bool Goals(JsonObject? body) => body != null && body.Int("goal_pages") != null;
    public static bool Terminal(JsonObject? body) => body?.Bool("terminal") == true;
    public static bool TaskFields(JsonObject? body) => body?.Bool("task_fields") == true;
    public static bool TravelCards(JsonObject? body) => body?.Bool("travelCards") == true;
    public static bool TravelCardsShown(JsonObject? body) => body?.Bool("travelCardsShown") == true;
    public static bool TravelCardsKnown(JsonObject? body) => body?.Bool("travelCards") != null;
    public static bool ShoppingCards(JsonObject? body) => body?.Bool("shoppingCards") == true;
    public static bool ShoppingCardsShown(JsonObject? body) => body?.Bool("shoppingCardsShown") == true;
    public static bool ShoppingCardsKnown(JsonObject? body) => body?.Bool("shoppingCards") != null;
    public static bool DraftCards(JsonObject? body) => body?.Bool("draftCards") == true;
    public static bool DraftCardsShown(JsonObject? body) => body?.Bool("draftCardsShown") == true;
    public static bool DraftCardsKnown(JsonObject? body) => body?.Bool("draftCards") != null;
    public static bool ActCards(JsonObject? body) => body?.Bool("actCards") == true;
    public static bool ActCardsShown(JsonObject? body) => body?.Bool("actCardsShown") == true;
    public static bool ActCardsKnown(JsonObject? body) => body?.Bool("actCards") != null;
    public static bool ToolPermissions(JsonObject? body) => body?.Bool("toolPermissions") == true;
    public static bool ToolPermissionsAsk(JsonObject? body) => body?.Bool("toolPermissionsAsk") != false;
    public static string? PluginVersion(JsonObject? body) => body?.Str("pluginVersion");

    public static bool VersionAtLeast(string? version, string minimum)
    {
        if (string.IsNullOrWhiteSpace(version)) return false;
        static int[] Parse(string s) => [.. s.Split('.', StringSplitOptions.RemoveEmptyEntries).Select(p =>
        {
            var digits = new string([.. p.TakeWhile(char.IsDigit)]);
            return int.TryParse(digits, out var n) ? n : 0;
        })];
        var a = Parse(version);
        var b = Parse(minimum);
        var len = Math.Max(a.Length, b.Length);
        for (var i = 0; i < len; i++)
        {
            var av = i < a.Length ? a[i] : 0;
            var bv = i < b.Length ? b[i] : 0;
            if (av != bv) return av > bv;
        }
        return true;
    }

    /// Reads add-on status from the signed-in gateway (`/api/plugins/hermes-hq-push/status`).
    public static async Task<PushAddonStatus> ReadStatusAsync(GatewaySession session, CancellationToken ct = default)
    {
        try
        {
            var node = await session.GetJsonAsync(PluginRoute + "/status", timeout: TimeSpan.FromSeconds(10), ct: ct) as JsonObject;
            if (node == null) return new(Installed: false, Version: null, Seals: false, Tasks: false, Goals: false, Kinds: [], Error: null);
            return new(
                Installed: true,
                Version: PluginVersion(node),
                Seals: Seals(node),
                Tasks: Tasks(node),
                Goals: Goals(node),
                Kinds: [.. Kinds(node).OrderBy(x => x, StringComparer.Ordinal)],
                Error: null,
                TravelCards: TravelCards(node),
                TravelCardsShown: TravelCardsShown(node),
                ShoppingCards: ShoppingCards(node),
                ShoppingCardsShown: ShoppingCardsShown(node),
                DraftCards: DraftCards(node),
                DraftCardsShown: DraftCardsShown(node),
                ActCards: ActCards(node),
                ActCardsShown: ActCardsShown(node),
                ToolPermissions: ToolPermissions(node),
                ToolPermissionsAsk: ToolPermissionsAsk(node));
        }
        catch (GatewayException ex) when (ex.Status == 404)
        {
            return new(Installed: false, Version: null, Seals: false, Tasks: false, Goals: false, Kinds: [], Error: null);
        }
        catch (Exception ex) when (ex is GatewayException or HttpRequestException or OperationCanceledException)
        {
            return new(Installed: false, Version: null, Seals: false, Tasks: false, Goals: false, Kinds: [], Error: ex.Message);
        }
    }

    /// Tells the push add-on this app renders flight & hotel cards (`PUT /api/plugins/hermes-hq-push/travel/cards`).
    public static Task<bool> EnableTravelCardsAsync(GatewaySession session, CancellationToken ct = default) =>
        PutCapabilityAsync(session, "/travel/cards", ct);

    /// Tells the push add-on this app renders product & order cards (`PUT /api/plugins/hermes-hq-push/shopping/cards`).
    public static Task<bool> EnableShoppingCardsAsync(GatewaySession session, CancellationToken ct = default) =>
        PutCapabilityAsync(session, "/shopping/cards", ct);

    /// Tells the push add-on this app renders draft cards (`PUT /api/plugins/hermes-hq-push/drafts/cards`).
    public static Task<bool> EnableDraftCardsAsync(GatewaySession session, CancellationToken ct = default) =>
        PutCapabilityAsync(session, "/drafts/cards", ct);

    /// Tells the push add-on this app renders ask-to-act cards (`PUT /api/plugins/hermes-hq-push/asks/cards`).
    public static Task<bool> EnableAskCardsAsync(GatewaySession session, CancellationToken ct = default) =>
        PutCapabilityAsync(session, "/asks/cards", ct);

    /// Performs capability handshakes for any card family the add-on supports but has not yet been told this app draws
    /// (App/Notifications/PushRegistrar.swift `probe`).
    public static async Task SyncCardCapabilitiesAsync(GatewaySession session, PushAddonStatus status, CancellationToken ct = default)
    {
        if (!status.Installed) return;
        if (status.DraftCards && !status.DraftCardsShown)
            await EnableDraftCardsAsync(session, ct).ConfigureAwait(false);
        if (status.ShoppingCards && !status.ShoppingCardsShown)
            await EnableShoppingCardsAsync(session, ct).ConfigureAwait(false);
        if (status.TravelCards && !status.TravelCardsShown)
            await EnableTravelCardsAsync(session, ct).ConfigureAwait(false);
        if (status.ActCards && !status.ActCardsShown)
            await EnableAskCardsAsync(session, ct).ConfigureAwait(false);
    }

    private static async Task<bool> PutCapabilityAsync(GatewaySession session, string subPath, CancellationToken ct)
    {
        try
        {
            var answer = await session.SendAsync(HttpMethod.Put, PluginRoute + subPath, timeout: TimeSpan.FromSeconds(10), ct: ct)
                .ConfigureAwait(false);
            return answer.Ok;
        }
        catch (Exception ex) when (ex is GatewayException or HttpRequestException or OperationCanceledException)
        {
            return false;
        }
    }
}

public sealed record PushAddonStatus(
    bool Installed,
    string? Version,
    bool Seals,
    bool Tasks,
    bool Goals,
    IReadOnlyList<string> Kinds,
    string? Error,
    bool TravelCards = false,
    bool TravelCardsShown = false,
    bool ShoppingCards = false,
    bool ShoppingCardsShown = false,
    bool DraftCards = false,
    bool DraftCardsShown = false,
    bool ActCards = false,
    bool ActCardsShown = false,
    bool ToolPermissions = false,
    bool ToolPermissionsAsk = true);
