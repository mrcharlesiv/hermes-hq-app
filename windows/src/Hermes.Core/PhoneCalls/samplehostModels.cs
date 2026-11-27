using System.Text.Json.Nodes;

namespace Hermes.Core.PhoneCalls;

/// Strict endpoint policy matching `samplehostClient.swift`: production HTTPS `api.samplehost.com/v2` only,
/// with optional loopback override strictly for local tests.
public static class samplehostEndpoint
{
    public static readonly Uri Production = new("https://api.samplehost.com/v2");

    public static bool IsAllowed(Uri uri, bool allowLoopback = false)
    {
        if (!uri.IsAbsoluteUri) return false;
        if (string.Equals(uri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase)
            && string.Equals(uri.Host, "api.samplehost.com", StringComparison.OrdinalIgnoreCase))
            return true;

        if (allowLoopback && uri.IsLoopback
            && (string.Equals(uri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase)
                || string.Equals(uri.Scheme, Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase)))
            return true;

        return false;
    }
}

public enum samplehostErrorKind
{
    NoKey,
    RejectedHost,
    Unauthorized,
    Forbidden,
    NotFound,
    PaymentRequired,
    RateLimited,
    ServerError,
    Network,
    InvalidResponse,
    HttpError,
}

public sealed class samplehostException(samplehostErrorKind kind, string message, int? statusCode = null, Exception? inner = null)
    : Exception(message, inner)
{
    public samplehostErrorKind Kind { get; } = kind;
    public int? StatusCode { get; } = statusCode;
}

/// Safe user-facing error formatting that guarantees samplehost API keys are never exposed in logs, UI, or shares.
public static class PhoneMessages
{
    public static string Redact(string text, string? apiKey)
    {
        if (string.IsNullOrEmpty(text)) return "";
        if (string.IsNullOrWhiteSpace(apiKey)) return text;
        var key = apiKey.Trim();
        return key.Length >= 6 ? text.Replace(key, "[redacted]", StringComparison.Ordinal) : text;
    }

    public static string Format(Exception error, string? apiKey = null)
    {
        var raw = error switch
        {
            samplehostException { Kind: samplehostErrorKind.NoKey } => "Add your samplehost API key in Phone Settings first.",
            samplehostException { Kind: samplehostErrorKind.Unauthorized } => "samplehost rejected that API key. Check your key in Phone Settings.",
            samplehostException { Kind: samplehostErrorKind.Forbidden } => "Your samplehost API key doesn’t have permission for this action.",
            samplehostException { Kind: samplehostErrorKind.PaymentRequired } => "Your samplehost balance is too low to place a call.",
            samplehostException { Kind: samplehostErrorKind.RateLimited } => "samplehost rate limit reached. Try again in a moment.",
            samplehostException { Kind: samplehostErrorKind.RejectedHost } => "Refused to send samplehost credentials to an untrusted host.",
            samplehostException { Kind: samplehostErrorKind.Network } => "Couldn’t reach samplehost. Check your internet connection.",
            samplehostException { Kind: samplehostErrorKind.ServerError } => "samplehost had a temporary server error. Try again shortly.",
            samplehostException te => te.Message,
            HttpRequestException => "Couldn’t reach samplehost. Check your internet connection.",
            TaskCanceledException => "The request to samplehost timed out.",
            _ => string.IsNullOrWhiteSpace(error.Message) ? "Something went wrong with the phone call." : error.Message,
        };
        return Redact(raw, apiKey);
    }
}

public enum PhoneVoicemailChoice
{
    HangUp,
    LeaveMessage,
}

public static class PhoneLimits
{
    public const int MaxGoalChars = 1000;
    public const int MaxNameChars = 80;
    public const int MaxCallSeconds = 1800; // 30-minute safety stop
    public const int RingTimeoutSeconds = 45;
    public const int StraightToVoicemailSeconds = 3;
    public const int MaxHistoryCalls = 50;
    public const int MaxLinesPerCall = 300;
}

public sealed record samplehostNumber(string PhoneNumber, string? ConnectionId = null, string? ConnectionName = null, string? Status = null);

public sealed record samplehostAssistant(string Id, string Name, string? Model = null, string? Voice = null);

public sealed record samplehostAssistantDetail(
    string Id,
    string Name,
    string? Model,
    bool TelephonyEnabled,
    bool RecordingEnabled,
    string? Voice = null);

public sealed record samplehostToolCall(string Id, string Name, string ArgumentsJson);

public sealed record samplehostMessage(
    string Id,
    string Role,
    string Text,
    DateTimeOffset? CreatedAt = null,
    IReadOnlyList<samplehostToolCall>? ToolCalls = null,
    string? ToolCallId = null);

public sealed record samplehostDialed(string CallControlId, string CallLegId, string? CallSessionId = null);

public sealed record samplehostCallStatus(
    string CallControlId,
    bool IsAlive,
    string State,
    string? HangupCause = null,
    DateTimeOffset? AnsweredAt = null,
    DateTimeOffset? EndedAt = null);

public sealed record samplehostBalance(decimal Amount, string Currency = "USD");

public sealed record samplehostCallControlApp(string Id, string Name, string? OutboundVoiceProfileId = null, bool Active = true);

public sealed record samplehostVoiceProfile(string Id, string Name, IReadOnlyList<string> WhitelistedDestinations, bool Enabled = true);

public sealed record samplehostConversationInsight(string Summary, DateTimeOffset? CreatedAt = null);

/// `ask_owner` tool contract allowing the live AI caller to pause and ask the user a question mid-call.
public static class PhoneAskOwner
{
    public const string ToolName = "ask_owner";

    public static string Instructions(string ownerName)
    {
        var owner = string.IsNullOrWhiteSpace(ownerName) ? "the owner" : ownerName.Trim();
        return $"You are calling on behalf of {owner}. Be concise, polite, and clear. "
            + $"If the other party asks a question you cannot answer or asks for confirmation, call `{ToolName}` "
            + "with a short question and optional quick-reply choices, then wait for the answer before responding.";
    }

    public static JsonObject ToolDefinition() => new()
    {
        ["type"] = "webhook",
        ["webhook"] = new JsonObject
        {
            ["name"] = ToolName,
            ["description"] = "Ask the caller's owner a short question when confirmation or missing information is needed.",
            ["parameters"] = new JsonObject
            {
                ["type"] = "object",
                ["properties"] = new JsonObject
                {
                    ["question"] = new JsonObject { ["type"] = "string", ["description"] = "Short question for the owner." },
                    ["choices"] = new JsonObject
                    {
                        ["type"] = "array",
                        ["items"] = new JsonObject { ["type"] = "string" },
                        ["description"] = "Optional short quick-reply choices.",
                    },
                },
                ["required"] = new JsonArray("question"),
            },
        },
    };
}

public sealed record PhoneDialRequest(
    string To,
    string From,
    string ConnectionId,
    string AssistantId,
    string Goal,
    string? TargetName,
    PhoneVoicemailChoice Voicemail,
    string OwnerName,
    bool Record,
    string IdempotencyKey);

/// Per-account phone calling configuration (`PhoneSetup` in `PhoneCalls.swift` + `PhoneVoicePage.swift`).
public sealed record PhoneSetup
{
    public string? FromNumber { get; init; }
    public string? ConnectionId { get; init; }
    public string? AssistantId { get; init; }
    public string OwnerName { get; init; } = "";
    public bool RecordCalls { get; init; }
    public bool SendResultsToChat { get; init; } = true;
    public string? PreferredVoice { get; init; }

    public bool HasRequiredFields =>
        PhoneFormatting.IsE164(FromNumber)
        && !string.IsNullOrWhiteSpace(ConnectionId)
        && !string.IsNullOrWhiteSpace(AssistantId);

    public JsonObject ToJson() => new()
    {
        ["from_number"] = FromNumber,
        ["connection_id"] = ConnectionId,
        ["assistant_id"] = AssistantId,
        ["owner_name"] = OwnerName,
        ["record_calls"] = RecordCalls,
        ["send_results"] = SendResultsToChat,
        ["preferred_voice"] = PreferredVoice,
    };

    public static PhoneSetup FromJson(JsonNode? node)
    {
        if (node is not JsonObject) return new PhoneSetup();
        return new PhoneSetup
        {
            FromNumber = node.Text("from_number"),
            ConnectionId = node.Text("connection_id"),
            AssistantId = node.Text("assistant_id"),
            OwnerName = node.Text("owner_name") ?? "",
            RecordCalls = node.Bool("record_calls") ?? false,
            SendResultsToChat = node.Bool("send_results") ?? true,
            PreferredVoice = node.Text("preferred_voice"),
        };
    }
}

/// Secure secret store for per-account samplehost API keys (`PhoneKeychain` counterpart).
public interface IPhoneKeyStore
{
    string? ReadKey(string accountId);
    void SaveKey(string accountId, string apiKey);
    void DeleteKey(string accountId);
}

public sealed class MemoryPhoneKeyStore : IPhoneKeyStore
{
    private readonly Dictionary<string, string> _keys = new(StringComparer.Ordinal);
    public string? ReadKey(string accountId) => _keys.TryGetValue(accountId, out var k) ? k : null;
    public void SaveKey(string accountId, string apiKey) => _keys[accountId] = apiKey.Trim();
    public void DeleteKey(string accountId) => _keys.Remove(accountId);
}
