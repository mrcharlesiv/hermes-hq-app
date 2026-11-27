namespace Hermes.Core.Net;

/// A failure the UI can word plainly. Codes match HermesKit's (spec 01): invalid-url, insecure-url, not-hermes,
/// gateway-outdated, no-password, host-rejected, rate-limited, nous-unavailable, nous-failed, nous-cancelled,
/// not-owner, timeout, session-ended, http, rpc.
public sealed class GatewayException(string code, string message, int status = 0, string? body = null,
    TimeSpan? retryAfter = null, long rpcCode = 0) : Exception(message)
{
    public string Code { get; } = code;
    public int Status { get; } = status;
    public string? Body { get; } = body;
    public TimeSpan? RetryAfter { get; } = retryAfter;
    /// JSON-RPC error code (4001, 4007, 4009, …) when Code == "rpc"; ConnectionLostCode or NotConnectedCode on an
    /// "offline" one the socket raised.
    public long RpcCode { get; } = rpcCode;
    /// The call a ConnectionLost failure was waiting on (for the log; never shown).
    public string? Method { get; init; }

    // [WIN-RPC-DROP-PENDING] HermesKit/Net/GatewayFailure.swift's client-side RPCError codes: outside the gateway's own
    // (positive 4xxx/5032) and JSON-RPC's (-32700…-32600) ranges.
    public const long ConnectionLostCode = -33002;
    public const long NotConnectedCode = -33003;

    /// The socket closed before the gateway answered (RPCError.connectionLost): the gateway may still have done it, so
    /// a prompt.submit is "Delivery unconfirmed", never resent.
    public bool IsConnectionLost => Code == "offline" && RpcCode == ConnectionLostCode;
    /// The call never reached a gateway (RPCError.notSent): no socket was up. Safe to refuse and send again.
    public bool IsNotConnected => Code == "offline" && RpcCode == NotConnectedCode;

    /// RPCError.connectionLost(method): the client's own line (for logs, Show Details and MemoUploader.words), never
    /// the alert's reason (that is PlainReason).
    public static GatewayException ConnectionLost(string method) =>
        new("offline", $"connection closed before the gateway answered: {method}", rpcCode: ConnectionLostCode) { Method = method };

    public static GatewayException NotConnected() =>
        new("offline", "Not connected to the gateway.", rpcCode: NotConnectedCode) { NotSentBecause = SocketDeadReason };

    // [WIN-SEND-NOTSENT-REFUSE] RPCError.notSent(failure) (HermesKit/Net/GatewayFailure.swift at 93f984bb1): the call never
    // reached a gateway; its words are the failure's message and `NotSentBecause` its stable code (`data.reason`).
    public static GatewayException NotSent(string reason) =>
        new("offline", NotSentWords(reason), rpcCode: NotConnectedCode) { NotSentBecause = reason };

    /// Why a not-sent call never went out (GatewayFailure.code: "timeout", "socket-dead", "network", "paused",
    /// "signed-out", …); null for any other error (`notSentBecause`).
    public string? NotSentBecause
    {
        get => IsNotConnected ? _notSentBecause : null;
        init => _notSentBecause = value;
    }
    private readonly string? _notSentBecause;

    public const string SocketDeadReason = "socket-dead";

    /// LiveChatSession.linkAwayForNow: a not-sent call whose link is only away for now (offline, reconnecting, paused,
    /// the socket wait ran out); a sign-out, an ended session, a changed connection or a missing account is not.
    public static bool LinkAwayForNow(GatewayException e) =>
        e.NotSentBecause is { } why && why is not ("signed-out" or "session-ended" or "connection-changed" or "account-missing");

    /// GatewayFailure.forCode(reason).message (HostWord/DeviceWord as Windows says them); an unknown code reads as the
    /// timeout's words (`out.failure.value ?? .timeout`).
    public static string NotSentWords(string reason) => reason switch
    {
        "socket-dead" => "Your gateway stopped answering. Reconnecting…",
        "network" => "You’re offline. Hermes HQ reconnects when the network is back.",
        "paused" => "Paused while Hermes HQ is in the background.",
        "connection-changed" => "The connection changed before your gateway answered. Try again.",
        "signed-out" => "Sign in to your gateway to continue.",
        "session-ended" => "Your session on this gateway ended. Sign in again.",
        "unreachable" => $"Can’t reach {Hermes.Core.Gateways.HostWord.Phrase}. Check that it’s on, and that Tailscale is on here too if you use it.",
        "rate-limited" => "Your gateway is busy right now. Wait a minute, then try again.",
        "gateway-error" => GatewayErrorWords,
        "not-hermes" => "That address answered, but it isn’t Hermes. Check the address, including any :port at the end.",
        "gateway-outdated" => $"{Hermes.Core.Gateways.HostWord.Sentence} has a version of Hermes that’s too old for Hermes HQ. Update Hermes there, then try again.",
        "tls" => $"This {Hermes.Core.Gateways.DeviceWord.Name} doesn’t trust your gateway’s HTTPS certificate. Use a certificate from a public authority, such as Tailscale HTTPS.",
        _ => TimeoutWords,
    };

    // [WIN-CONNLOST-WORDS] The words RPCError.plainReason uses (HermesKit/Net/GatewayFailure.swift at 93f984bb1).
    public const string ConnectionLostWords =
        "The connection dropped before your gateway answered. Check that it went through, then try again.";
    /// GatewayFailure.timeout.message.
    public const string TimeoutWords = "Hermes didn’t answer in time. The computer running it may be busy, asleep or off.";
    /// GatewayFailure.gatewayError(nil).message.
    public const string GatewayErrorWords = "Your gateway couldn’t complete that. Try again.";
    /// plainReason's protocol line (HostWord.phrase is "the computer running Hermes" on Windows).
    public const string NotAcceptedWords = "Your gateway didn’t accept that request. Updating Hermes on the computer running Hermes may help.";

    private static readonly System.Text.RegularExpressions.Regex ProtocolWording = new(
        @"^\s*(invalid[ _]params|method not found|unknown method)", System.Text.RegularExpressions.RegexOptions.IgnoreCase);

    /// RPCError.plainReason: words for a failure alert (audit 10-2): the gateway's own sentence ("That name is taken."),
    /// never its protocol wording ("invalid params for prompt.submit: …", method not found) or a transport line
    /// ("connection closed before the gateway answered: projects.create"). For a failure that is not an RPC one on the
    /// Mac (http, an address or sign-in failure) it is the exception's own words.
    public string PlainReason
    {
        get
        {
            if (Code == "timeout") return TimeoutWords;
            if (IsConnectionLost) return ConnectionLostWords;
            if (IsNotConnected) return Message;
            if (Code != "rpc") return Message;
            if (RpcCode is -32601 or -32602 or -32600 || ProtocolWording.IsMatch(Message)) return NotAcceptedWords;
            var trimmed = Message.Trim();
            if (RpcCode is -32603 or -32700 || trimmed.Length == 0) return GatewayErrorWords;
            return trimmed;
        }
    }
}
