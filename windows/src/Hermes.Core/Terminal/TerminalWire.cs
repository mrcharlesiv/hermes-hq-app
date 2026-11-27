using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;

namespace Hermes.Core.Terminal;

/// The Terminal page's socket (docs/spec/terminal.md, HermesKit/Terminal/TerminalWire.swift): hermes-hq-push 0.9.25's
/// `/api/plugins/hermes-hq-push/terminal?session=<32 hex>&cols=&rows=&since=&ticket=…`, one socket per open tab.
/// Computer → app: binary frames are what the shell printed, in order; text frames are JSON: `ready` first (the bytes
/// after it start at byte `offset` of everything that shell printed), `exit` when the shell ends, `ping` after 20 s of
/// quiet. App → computer: binary frames are keys and pastes as typed; text frames `resize`, `end` and `ping`.
public static class TerminalWire
{
    public const string Route = "/api/plugins/hermes-hq-push";
    public const string Path = Route + "/terminal";
    /// The add-on sends frames of at most 64 KB; room for a burst of them and the JSON.
    public const int MaxMessage = 4 << 20;

    /// `wss://<gateway>/api/plugins/hermes-hq-push/terminal?…&ticket=…`; null for an address that isn't http(s).
    public static Uri? SocketUrl(Uri baseUrl, string basePath, IEnumerable<KeyValuePair<string, string>> query, string ticket)
    {
        var scheme = baseUrl.Scheme.ToLowerInvariant() switch { "https" => "wss", "http" => "ws", _ => null };
        if (scheme == null) return null;
        var sb = new StringBuilder(scheme).Append("://").Append(baseUrl.Authority).Append(basePath.TrimEnd('/')).Append(Path);
        var first = true;
        foreach (var (k, v) in query.Where(q => q.Key is not ("ticket" or "token")).Append(new("ticket", ticket)))
        {
            sb.Append(first ? '?' : '&').Append(Uri.EscapeDataString(k)).Append('=').Append(Uri.EscapeDataString(v));
            first = false;
        }
        return new Uri(sb.ToString());
    }

    public static List<KeyValuePair<string, string>> Query(string session, int cols, int rows, long since) =>
    [
        new("session", session), new("cols", cols.ToString()), new("rows", rows.ToString()), new("since", since.ToString()),
    ];

    /// A new shell's name: 32 lowercase hex characters, as the add-on checks.
    public static string NewSession() => Convert.ToHexString(RandomNumberGenerator.GetBytes(16)).ToLowerInvariant();

    public static bool IsSession(string text) => text.Length == 32 && text.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f');

    // MARK: Text frames

    public abstract record Message
    {
        public sealed record Ready(long Offset, string Shell, bool Resumed) : Message;
        public sealed record Exit(int? Code) : Message;
        public sealed record Ping : Message;
        public sealed record Pong : Message;
        public sealed record Other : Message;
    }

    public static Message Parse(string text)
    {
        if (J.Parse(text) is not JsonObject body) return new Message.Other();
        return body.Str("type") switch
        {
            "ready" => new Message.Ready(body.Int("offset") ?? 0, body.Str("shell") ?? "", body.Bool("resumed") ?? false),
            "exit" => new Message.Exit(body.Int("code") is { } c ? (int)c : null),
            "ping" => new Message.Ping(),
            "pong" => new Message.Pong(),
            _ => new Message.Other(),
        };
    }

    public static string Resize(int cols, int rows) => $"{{\"type\":\"resize\",\"cols\":{cols},\"rows\":{rows}}}";
    public const string End = "{\"type\":\"end\"}";
    public const string PingText = "{\"type\":\"ping\"}";

    // MARK: How a socket ended

    public enum EndingKind
    {
        /// The link dropped: dial again.
        Retry,
        /// The shell ended (its `exit` came first).
        Ended,
        /// Opened again from this device (another page took the shell): don't dial back.
        Replaced,
        /// plugin-data's terminal.off on the computer.
        Off,
        /// No terminal on that computer (Windows without pywinpty).
        Unsupported,
        /// Eight shells are open there already.
        Full,
        /// The shell couldn't start, or the add-on refused: its reason.
        Refused,
        /// Something on the way answered the socket 404 though the add-on has the Terminal.
        Blocked,
        /// The first dial never reached the shell after `TerminalConnection.GiveUpAfter` tries.
        Unreachable,
    }

    public sealed record Ending(EndingKind Kind, string? Reason = null);

    public static Ending EndingFor(int? code, string? reason, int? refused = null)
    {
        if (code == null && refused == 404) return new(EndingKind.Blocked);
        return code switch
        {
            1000 => new(EndingKind.Ended),
            4409 => new(EndingKind.Replaced),
            4403 => new(EndingKind.Off),
            4501 => new(EndingKind.Unsupported),
            4429 => new(EndingKind.Full),
            4400 or 4500 => new(EndingKind.Refused, string.IsNullOrEmpty(reason) ? "The computer refused the terminal." : reason),
            _ => new(EndingKind.Retry),
        };
    }

    /// For the log: the close code or HTTP answer, never the reason text (it can carry the shell's error).
    public static string Describe(int? code, int? refused, Ending ending)
    {
        var how = code is { } c ? $"close {c}" : refused is { } r ? $"HTTP {r}" : "no close frame";
        return $"{how} → {ending.Kind.ToString().ToLowerInvariant()}";
    }

    // MARK: The add-on (TerminalViewController.addOn, PushPolicy.terminal*)

    public enum AddOn { Ready, NeedsUpdate, Unsupported, Off, Unknown }

    /// The add-on's status (`GET /api/plugins/hermes-hq-push/status`): its `terminal` and `terminalOff` keys (0.9.25+).
    public static AddOn AddOnFrom(int status, JsonNode? body)
    {
        switch (status)
        {
            case 200:
                if (body.Get("terminal") is not JsonValue v || v.GetValueKind() is not (System.Text.Json.JsonValueKind.True or System.Text.Json.JsonValueKind.False or System.Text.Json.JsonValueKind.Number))
                    return AddOn.NeedsUpdate;
                if (body.Bool("terminal") != true) return AddOn.Unsupported;
                return body.Bool("terminalOff") == true ? AddOn.Off : AddOn.Ready;
            case 404: return AddOn.NeedsUpdate;
            default: return AddOn.Unknown;
        }
    }
}
