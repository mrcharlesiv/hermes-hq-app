// [WIN-SCREEN-WIRE-KEYS-MATH] Bot Screen's wire, the C# twin of the Mac's HermesKit/Screen/ScreenWire.swift at
// 93f984bb1 (docs/spec/3x-screen.md §2): the display status and lease as Hermes sends them, the exact params of the five
// `display.*` calls (Hermes answers an unknown param with error 4000), the viewer hash, the tone and kind rules, and the
// display socket's URL. Pure values; nothing here talks to the network.
//
// Reads are strict, as HermesKit's JSONValue is: a string field is only a JSON string (7 is no geometry), a flag only a
// JSON bool ("yes" is not supported), a number a JSON number or numeric string truncated (JSONValue.int). The Swift
// RPCError is Hermes.Core's GatewayException: Code "rpc" carries RpcCode, "timeout" is isTimeout and "offline" is
// isConnectionLost / isNotConnected.

using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hermes.Core.Net;

namespace Hermes.Core.Screen;

public enum ScreenHolder { Agent, Human }

/// Who controls the screen. A human holder is named by `ViewerHash`, never by id.
public sealed record ScreenLease(ScreenHolder Holder = ScreenHolder.Agent, string? ViewerHash = null, long Epoch = 0)
{
    /// null unless it is an object with a known holder (a wrong shape is "no lease known", never a crash).
    public static ScreenLease? Parse(JsonNode? value)
    {
        if (value is not JsonObject) return null;
        ScreenHolder? holder = ScreenJson.Str(value, "holder") switch { "agent" => ScreenHolder.Agent, "human" => ScreenHolder.Human, _ => null };
        if (holder is not { } known) return null;
        var hash = ScreenJson.Str(value, "viewer_hash");
        return new ScreenLease(known, string.IsNullOrEmpty(hash) ? null : hash, Math.Max(0, ScreenJson.Int(value, "epoch") ?? 0));
    }

    /// `V/screen-state.ts` isOlderLease: a lease with a lower epoch than the one held is ignored.
    public bool IsOlder(ScreenLease? other) => other != null && Epoch < other.Epoch;
}

public sealed record ScreenStatus
{
    public string? ProfileKey { get; init; }
    public bool Supported { get; init; }
    public bool Installed { get; init; }
    public bool Running { get; init; }
    public IReadOnlyList<string> Missing { get; init; } = [];
    public string? Display { get; init; }
    public string? Geometry { get; init; }
    public string? InstallCommand { get; init; }
    public string? Blocker { get; init; }
    public string? Placement { get; init; }
    public ScreenLease? Lease { get; init; }

    /// null unless the answer is an object. Every field is optional on read.
    public static ScreenStatus? Parse(JsonNode? value)
    {
        if (value is not JsonObject) return null;
        string? Text(string key) => ScreenJson.Str(value, key) is { } raw && ScreenWire.Plain(raw) is { Length: > 0 } text ? text : null;
        return new ScreenStatus
        {
            ProfileKey = ScreenJson.Str(value, "profile_key"),
            Supported = ScreenJson.Bool(value, "supported") == true,
            Installed = ScreenJson.Bool(value, "installed") == true,
            Running = ScreenJson.Bool(value, "running") == true,
            Missing = value["missing"] is JsonArray list ? list.Select(ScreenJson.AsString).OfType<string>().ToArray() : [],
            Display = ScreenJson.Str(value, "display"),
            Geometry = ScreenJson.Str(value, "geometry"),
            InstallCommand = ScreenJson.Str(value, "install_command"),
            Blocker = Text("blocker"),
            Placement = ScreenJson.Str(value, "placement"),
            Lease = ScreenLease.Parse(value["lease"]),
        };
    }

    /// The Mac's own console, shared by every bot on it.
    public bool IsMac => Display == "This Mac";
    /// `!running && blocker`: the gateway could share a screen but something stops it.
    public bool IsBlocked => !Running && Blocker != null;

    public bool Equals(ScreenStatus? other) =>
        other is not null && ProfileKey == other.ProfileKey && Supported == other.Supported && Installed == other.Installed
        && Running == other.Running && Missing.SequenceEqual(other.Missing) && Display == other.Display && Geometry == other.Geometry
        && InstallCommand == other.InstallCommand && Blocker == other.Blocker && Placement == other.Placement && Lease == other.Lease;

    public override int GetHashCode() => HashCode.Combine(ProfileKey, Supported, Installed, Running, Missing.Count, Display, Geometry, Lease);
}

/// A viewer id minted by `display.observe` and the hash the lease names it by.
public sealed record ScreenViewer(string Id)
{
    public string Hash { get; } = ScreenWire.ViewerHash(Id);
}

public sealed record ScreenObserved(ScreenStatus Status, string Ticket, string Path, ScreenViewer Viewer)
{
    public static ScreenObserved? Parse(JsonNode? value)
    {
        if (ScreenStatus.Parse(value) is not { } status || ScreenJson.Str(value, "ticket") is not { Length: > 0 } ticket
            || ScreenJson.Str(value, "path") is not { } path || ScreenJson.Str(value, "viewer_id") is not { Length: > 0 } id) return null;
        return new ScreenObserved(status, ticket, path, new ScreenViewer(id));
    }
}

/// What a bot's screen is doing (`V/screen-portal.tsx` portalTone).
public enum ScreenTone { Unknown, Unavailable, Unsupported, Missing, Off, Live, Human, Other }

/// What the Screen entry opens (`S/bot-screen-phone.tsx` screenMenuLabel).
public enum ScreenKind { Unknown, Live, Screenshots }

public static class ScreenKinds
{
    /// The Swift raw value ("unknown", "live", "screenshots"), as stored.
    public static string Raw(this ScreenKind kind) => kind switch
    {
        ScreenKind.Live => "live",
        ScreenKind.Screenshots => "screenshots",
        _ => "unknown",
    };

    public static ScreenKind? FromRaw(string? raw) => raw switch
    {
        "unknown" => ScreenKind.Unknown,
        "live" => ScreenKind.Live,
        "screenshots" => ScreenKind.Screenshots,
        _ => null,
    };

    public static string MenuTitle(this ScreenKind kind) => kind switch
    {
        ScreenKind.Screenshots => "Latest Screenshots",
        ScreenKind.Live => "Watch Screen",
        _ => "View Screen",
    };

    /// The Mac's SF Symbol name; the Windows view maps it to its own glyph.
    public static string Symbol(this ScreenKind kind) => kind == ScreenKind.Screenshots ? "photo.on.rectangle" : "display";
}

public static class ScreenWire
{
    public const string DisplayPath = "/api/display/ws";
    public const int MaxMessage = 4 * 1024 * 1024;
    public static readonly TimeSpan StatusTimeout = TimeSpan.FromSeconds(20);
    public static readonly TimeSpan StartTimeout = TimeSpan.FromSeconds(30);
    public static readonly TimeSpan ObserveTimeout = TimeSpan.FromSeconds(15);
    public static readonly TimeSpan LeaseTimeout = TimeSpan.FromSeconds(10);

    /// The display socket's close codes.
    public static class Close
    {
        public const int ControlTaken = 4000;
        public const int NotRunning = 4001;
        public const int Ticket = 4401;
        public const int NotAllowed = 4403;
        public const int ProtocolError = 1003;
    }

    // Params (exactly these keys)

    public static JsonObject ProfileParams(string profile) => new() { ["profile"] = profile };

    public static JsonObject ObserveParams(string profile, string? viewerId)
    {
        var p = new JsonObject { ["profile"] = profile };
        if (!string.IsNullOrEmpty(viewerId)) p["viewer_id"] = viewerId;
        return p;
    }

    public static JsonObject AcquireParams(string profile, string viewerId) => new() { ["profile"] = profile, ["viewer_id"] = viewerId };

    /// By id · by id with force (a hold this device lost track of) · bare with force (another viewer's hold).
    public static JsonObject ReleaseParams(string profile, string? viewerId, bool force)
    {
        var p = new JsonObject { ["profile"] = profile };
        if (!string.IsNullOrEmpty(viewerId)) p["viewer_id"] = viewerId;
        if (force) p["force"] = true;
        return p;
    }

    // Rules

    /// Older Hermes has no `display.*`: error -32601, or a message saying so.
    public static bool IsUnavailable(Exception error)
    {
        if (error is not GatewayException rpc) return false;
        if (rpc.RpcCode == -32601) return true;
        var text = rpc.Message.ToLowerInvariant();
        return text.Contains("method not found") || text.Contains("unknown method");
    }

    /// First 12 hex characters of SHA-256 of the viewer id (`HA/tools/bot_desktop/lease.py` public_view).
    public static string ViewerHash(string id) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(id))).ToLowerInvariant()[..12];

    public static bool Holds(ScreenLease? lease, ScreenViewer? viewer) =>
        lease != null && viewer != null && lease.Holder == ScreenHolder.Human && lease.ViewerHash == viewer.Hash;

    public static ScreenTone Tone(bool unavailable, ScreenStatus? status, ScreenViewer? viewer)
    {
        if (unavailable) return ScreenTone.Unavailable;
        if (status == null) return ScreenTone.Unknown;
        if (!status.Supported) return ScreenTone.Unsupported;
        if (!status.Installed) return ScreenTone.Missing;
        if (!status.Running) return ScreenTone.Off;
        if (status.Lease?.Holder == ScreenHolder.Human) return Holds(status.Lease, viewer) ? ScreenTone.Human : ScreenTone.Other;
        return ScreenTone.Live;
    }

    /// The kind a tone means, and what to remember for the gateway (null: remember nothing).
    public static (ScreenKind Kind, ScreenKind? Remember) Kind(ScreenTone tone, ScreenKind? remembered) => tone switch
    {
        ScreenTone.Unsupported or ScreenTone.Unavailable => (ScreenKind.Screenshots, ScreenKind.Screenshots),
        ScreenTone.Unknown => (remembered ?? ScreenKind.Unknown, null),
        _ => (ScreenKind.Live, ScreenKind.Live),
    };

    /// "This Mac · 1920×1080" (`S/bot-screen-phone.tsx` screenLabel): an X display number (":7") says nothing to a
    /// person and is left out; "WxH" reads "W×H".
    public static string ScreenLabel(ScreenStatus? status)
    {
        if (status == null) return "";
        var geometry = status.Geometry ?? "";
        var sides = geometry.Split('x');
        if (sides.Length == 2 && sides.All(s => s.Length > 0 && s.All(char.IsAsciiDigit))) geometry = $"{sides[0]}×{sides[1]}";
        var display = TrimSpaces(status.Display ?? "");
        if (display.Length > 1 && display[0] == ':' && display[1..].All(c => char.IsAsciiDigit(c) || c == '.')) display = "";
        return string.Join(" · ", new[] { display, geometry }.Where(s => s.Length > 0));
    }

    /// A geometry "1920x1080" as numbers (null when it is anything else).
    public static (int Width, int Height)? Size(string? geometry)
    {
        var parts = geometry?.Split('x', StringSplitOptions.RemoveEmptyEntries);
        if (parts is not { Length: 2 } || !SwiftInt(parts[0], out var w) || !SwiftInt(parts[1], out var h) || w <= 0 || h <= 0) return null;
        return (w, h);
    }

    /// `ws(s)://<gateway><prefix>/api/display/ws?display_ticket=<ticket>`: the ticket is the only credential that route
    /// takes. null (never dialled) when `path` is anything but `/api/display/ws`.
    public static Uri? DisplaySocketUrl(Uri @base, string path, string ticket)
    {
        if (path != DisplayPath || string.IsNullOrEmpty(ticket) || !@base.IsAbsoluteUri) return null;
        var scheme = @base.Scheme.ToLowerInvariant() switch { "https" => "wss", "http" => "ws", _ => null };
        if (scheme == null) return null;
        var basePath = @base.AbsolutePath;
        var prefix = basePath.EndsWith('/') ? basePath[..^1] : basePath;
        var builder = new UriBuilder(@base)
        {
            Scheme = scheme,
            Port = @base.IsDefaultPort ? -1 : @base.Port,
            UserName = "",
            Password = "",
            Fragment = "",
            Path = prefix + path,
            Query = "display_ticket=" + Uri.EscapeDataString(ticket),
        };
        return builder.Uri;
    }

    // Text the gateway wrote (D27)

    private static readonly Regex OldHelper = new("dispatch[ \u00A0]screen", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    private static readonly Regex OldPlugin = new("dispatch-screen", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    private static readonly Regex OldName = new("dispatch", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    /// Gateway-written text before it is shown or spoken: a Mac that still runs the pre-rename plugin words its
    /// messages with the old product name, which never appears on screen.
    public static string Plain(string text)
    {
        var out_ = OldHelper.Replace(text, "Hermes HQ Screen");
        out_ = OldPlugin.Replace(out_, "hermes-hq-screen");
        out_ = OldName.Replace(out_, "Hermes HQ");
        return out_.Trim();
    }

    /// A failed call in words a person can read.
    public static string Message(Exception error)
    {
        switch (error)
        {
            case GatewayException { Code: "timeout" }:
                return "The gateway took too long to answer.";
            case GatewayException { Code: "offline" }:
                return "The connection to the gateway was lost.";
            case GatewayException { Code: "rpc" } rpc:
                var text = Plain(rpc.Message);
                return text.Length == 0 ? "The gateway refused the request." : text;
            case GatewayException failure when failure.Message.Length > 0:
                return failure.Message;           // GatewayFailure.errorDescription: already this app's words
            case OperationCanceledException:
                return "The request was cancelled.";
            default:
                return Plain(error.Message);
        }
    }

    /// `<text without its trailing period>.` (one period, not two).
    public static string Sentence(string text) => text.Trim().TrimEnd('.') + ".";

    /// Swift's `.whitespaces`: tabs and the Unicode space separators, never line breaks.
    private static string TrimSpaces(string text)
    {
        static bool Space(char c) => c == '\t' || CharUnicodeInfo.GetUnicodeCategory(c) == UnicodeCategory.SpaceSeparator;
        int start = 0, end = text.Length;
        while (start < end && Space(text[start])) start++;
        while (end > start && Space(text[end - 1])) end--;
        return text[start..end];
    }

    /// Swift's `Int(String)`: an optional sign and ASCII digits, nothing else.
    private static bool SwiftInt(string text, out int value) =>
        int.TryParse(text, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out value);
}

/// Strict reads, as HermesKit's JSONValue accessors.
internal static class ScreenJson
{
    public static string? AsString(JsonNode? node) =>
        node is JsonValue v && v.GetValueKind() == JsonValueKind.String ? v.GetValue<string>() : null;

    public static string? Str(JsonNode? node, string key) => node is JsonObject o && o.TryGetPropertyValue(key, out var v) ? AsString(v) : null;

    public static bool? Bool(JsonNode? node, string key) =>
        node is JsonObject o && o.TryGetPropertyValue(key, out var v) && v is JsonValue jv
            ? jv.GetValueKind() switch { JsonValueKind.True => true, JsonValueKind.False => false, _ => null }
            : null;

    /// JSONValue.double: a number, or a string that reads as one.
    public static double? Double(JsonNode? node, string key)
    {
        if (node is not JsonObject o || !o.TryGetPropertyValue(key, out var v) || v is not JsonValue jv) return null;
        return jv.GetValueKind() switch
        {
            JsonValueKind.Number => jv.GetValue<double>(),
            JsonValueKind.String when double.TryParse(jv.GetValue<string>(), NumberStyles.Float, CultureInfo.InvariantCulture, out var d) => d,
            _ => null,
        };
    }

    /// JSONValue.int: the double truncated; null for NaN, ±inf and values past Int's range.
    public static long? Int(JsonNode? node, string key) =>
        Double(node, key) is { } d && double.IsFinite(d) && Math.Abs(d) < 9.2e18 ? (long)d : null;
}
