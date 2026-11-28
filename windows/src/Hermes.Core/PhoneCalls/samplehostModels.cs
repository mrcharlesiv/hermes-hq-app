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
    CallEnded,
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
    public bool IsNotFound => Kind == samplehostErrorKind.NotFound || StatusCode == 404;
}

/// Safe user-facing error formatting that guarantees samplehost API keys are never exposed in logs, UI, or shares.
public static class PhoneMessages
{
    public static string Redact(string text, string? apiKey)
    {
        if (string.IsNullOrEmpty(text)) return "";
        if (string.IsNullOrWhiteSpace(apiKey)) return text;
        var key = apiKey.Trim();
        return key.Length >= 4 ? text.Replace(key, "[redacted]", StringComparison.Ordinal) : text;
    }

    /// Adds plain-language guidance to samplehost's most common setup rejections while keeping samplehost's own error text.
    public static string FriendlyProviderMessage(string detail)
    {
        var trimmed = detail.Trim();
        if (trimmed.Length == 0) return "The phone request couldn’t be completed. Try again.";
        var lower = trimmed.ToLowerInvariant();
        if (lower.Contains("connection_id", StringComparison.Ordinal)
            && (lower.Contains("call control", StringComparison.Ordinal)
                || lower.Contains("webhook", StringComparison.Ordinal)
                || lower.Contains("invalid", StringComparison.Ordinal)
                || lower.Contains("does not exist", StringComparison.Ordinal)))
        {
            return $"samplehost: {trimmed} Open Phone Settings to choose or create a Voice API (Call Control) connection — TeXML applications created for AI Assistants can’t place calls here.";
        }
        if (lower.Contains("verified", StringComparison.Ordinal)
            && (lower.Contains("level", StringComparison.Ordinal)
                || lower.Contains("destination", StringComparison.Ordinal)
                || lower.Contains("unverified", StringComparison.Ordinal)))
        {
            return $"samplehost: {trimmed} New samplehost accounts at Level 1 can only call Verified Numbers until Level 2 verification is completed in the samplehost portal.";
        }
        return trimmed.StartsWith("samplehost:", StringComparison.OrdinalIgnoreCase) ? trimmed : $"samplehost: {trimmed}";
    }

    public static string Format(Exception error, string? apiKey = null)
    {
        var raw = error switch
        {
            samplehostException { Kind: samplehostErrorKind.NoKey } => "Add your samplehost API key in Phone Settings first.",
            samplehostException { Kind: samplehostErrorKind.Unauthorized } => "samplehost rejected that API key. Check your key in Phone Settings.",
            samplehostException { Kind: samplehostErrorKind.Forbidden } => "Your samplehost API key doesn’t have permission for this action.",
            samplehostException { Kind: samplehostErrorKind.CallEnded } => "This call has already ended.",
            samplehostException { Kind: samplehostErrorKind.PaymentRequired } => "Your samplehost balance is too low to place a call.",
            samplehostException { Kind: samplehostErrorKind.RateLimited } => "samplehost rate limit reached. Try again in a moment.",
            samplehostException { Kind: samplehostErrorKind.RejectedHost } => "Refused to send samplehost credentials to an untrusted host.",
            samplehostException { Kind: samplehostErrorKind.Network } => "Couldn’t reach samplehost. Check your internet connection.",
            samplehostException { Kind: samplehostErrorKind.ServerError } => "samplehost had a temporary server error. Try again shortly.",
            samplehostException { Kind: samplehostErrorKind.NotFound or samplehostErrorKind.HttpError } te
                when !string.IsNullOrWhiteSpace(te.Message) => FriendlyProviderMessage(te.Message),
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
    /// Never resolves (RFC 2606 `.invalid`), so the ask_owner webhook sends nothing anywhere.
    public const string AskOwnerUrl = "https://ask-owner.invalid/hermes-hq";
    /// Default webhook URL for a Voice API (Call Control) application created by Hermes HQ.
    public const string VoiceWebhookUrl = "https://voice-events.invalid/hermes-hq";
    public const string VoiceAppName = "Hermes HQ Voice";
    public const string VoiceProfileName = "Hermes HQ Outbound";
}

public sealed record samplehostNumber(
    string PhoneNumber,
    string? ConnectionId = null,
    string? ConnectionName = null,
    string? Status = null,
    string? Id = null);

public sealed record samplehostAssistant(string Id, string Name, string? Model = null, string? Voice = null);

public sealed record samplehostAssistantDetail(
    string Id,
    string Name,
    string? Model,
    bool TelephonyEnabled,
    bool RecordingEnabled,
    string? Voice = null,
    string? TranscriptionModel = null,
    bool? InterruptionEnabled = null,
    int? UserIdleTimeoutSecs = null,
    int? UserIdleReplySecs = null,
    int? GreetingDelayMs = null,
    string? NoiseSuppression = null,
    string? Greeting = null,
    IReadOnlyList<string>? EnabledFeatures = null,
    string? TelephonySettingsJson = null)
{
    /// Suboptimal stored settings observed on an existing assistant that affect live call fluidity (H14).
    public IReadOnlyList<string> CallQualityIssues
    {
        get
        {
            var issues = new List<string>();
            if (!string.IsNullOrWhiteSpace(TranscriptionModel)
                && !string.Equals(TranscriptionModel, "deepgram/flux", StringComparison.Ordinal))
            {
                issues.Add($"speech recognition uses {TranscriptionModel} instead of deepgram/flux");
            }
            if (InterruptionEnabled == false)
                issues.Add("interruptions are turned off");
            if (UserIdleTimeoutSecs is < 60)
                issues.Add($"silence timeout is only {UserIdleTimeoutSecs}s");
            if (UserIdleReplySecs is > 6)
                issues.Add($"silent-pickup wait is {UserIdleReplySecs}s");
            if (GreetingDelayMs is > 1000)
                issues.Add($"greeting delay is {GreetingDelayMs}ms");
            if (!string.IsNullOrWhiteSpace(NoiseSuppression)
                && !string.Equals(NoiseSuppression, "aicoustics", StringComparison.Ordinal))
            {
                issues.Add($"noise suppression uses {NoiseSuppression} instead of aicoustics");
            }
            return issues;
        }
    }
}

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

public sealed record samplehostCallControlApp(
    string Id,
    string Name,
    string? OutboundVoiceProfileId = null,
    bool Active = true,
    string? WebhookEventUrl = null);

public sealed record samplehostCallControlAppSummary(
    string Id,
    string? ApplicationName = null,
    bool? Active = null,
    string? WebhookEventUrl = null,
    string? OutboundVoiceProfileId = null);

public sealed record samplehostVoiceProfile(string Id, string Name, IReadOnlyList<string> WhitelistedDestinations, bool Enabled = true);

public sealed record samplehostConversationInsight(string Summary, DateTimeOffset? CreatedAt = null);

/// Resolves valid Voice API (Call Control) connections and detects when a samplehost number or saved setup points at a
/// TeXML or SIP connection instead (`POST /v2/calls` only accepts Call Control applications with a valid webhook URL).
public static class PhoneConnectionResolver
{
    public sealed record Option(string Id, string Name);

    /// Valid choices for the Voice connection picker. When `apps` was fetched (`!= null`), only real Call Control
    /// applications are offered so TeXML applications cannot be mistaken for a Voice API connection.
    public static IReadOnlyList<Option> Options(
        IReadOnlyList<samplehostNumber> numbers,
        IReadOnlyList<samplehostCallControlAppSummary>? apps)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var list = new List<Option>();
        if (apps != null)
        {
            foreach (var app in apps)
            {
                if (string.IsNullOrWhiteSpace(app.Id) || !seen.Add(app.Id)) continue;
                var label = string.IsNullOrWhiteSpace(app.ApplicationName) ? app.Id : app.ApplicationName!;
                list.Add(new Option(app.Id, label));
            }
            return list;
        }
        foreach (var n in numbers)
        {
            if (string.IsNullOrWhiteSpace(n.ConnectionId) || !seen.Add(n.ConnectionId)) continue;
            var label = string.IsNullOrWhiteSpace(n.ConnectionName) ? n.ConnectionId : n.ConnectionName!;
            list.Add(new Option(n.ConnectionId, label));
        }
        return list;
    }

    /// Picks the best Voice API connection when a From number is chosen or loaded. Never auto-selects a TeXML or SIP
    /// connection when `apps` is known.
    public static string PreferredConnection(
        string pickedNumber,
        IReadOnlyList<samplehostNumber> numbers,
        IReadOnlyList<samplehostCallControlAppSummary>? apps,
        string current = "")
    {
        var matchedNumber = numbers.FirstOrDefault(n => string.Equals(n.PhoneNumber, pickedNumber, StringComparison.Ordinal));
        if (apps == null)
        {
            return !string.IsNullOrWhiteSpace(matchedNumber?.ConnectionId) ? matchedNumber.ConnectionId! : current;
        }
        var validIds = apps.Where(a => !string.IsNullOrWhiteSpace(a.Id)).Select(a => a.Id).ToHashSet(StringComparer.Ordinal);
        if (!string.IsNullOrWhiteSpace(matchedNumber?.ConnectionId) && validIds.Contains(matchedNumber.ConnectionId!))
            return matchedNumber.ConnectionId!;
        if (!string.IsNullOrWhiteSpace(current) && validIds.Contains(current))
            return current;
        if (apps.Count == 1 && !string.IsNullOrWhiteSpace(apps[0].Id))
            return apps[0].Id;
        var readyApps = apps.Where(a => samplehostApi.HasValidWebhookUrl(a.WebhookEventUrl) && !string.IsNullOrWhiteSpace(a.Id)).ToList();
        if (readyApps.Count == 1)
            return readyApps[0].Id;
        return "";
    }

    /// True when a Call Control app is missing a valid `https://` webhook URL or an attached outbound voice profile (H14).
    public static bool NeedsFix(samplehostCallControlAppSummary app) =>
        !samplehostApi.HasValidWebhookUrl(app.WebhookEventUrl)
        || string.IsNullOrWhiteSpace(app.OutboundVoiceProfileId);

    /// True when `connectionId` is known to NOT be an active Call Control application (for example, a TeXML app).
    public static bool IsInvalidSavedConnection(string? connectionId, IReadOnlyList<samplehostCallControlAppSummary>? apps) =>
        apps != null
        && !string.IsNullOrWhiteSpace(connectionId)
        && !apps.Any(a => string.Equals(a.Id, connectionId, StringComparison.Ordinal));

    /// Explains why a saved connection or a number's current samplehost connection (such as an AI Assistant's TeXML app)
    /// cannot place outbound Voice API calls.
    public static string? NonCallControlWarning(
        samplehostNumber? selectedNumber,
        string? connectionId,
        IReadOnlyList<samplehostCallControlAppSummary>? apps)
    {
        if (apps == null) return null;
        var validIds = apps.Select(a => a.Id).ToHashSet(StringComparer.Ordinal);
        if (!string.IsNullOrWhiteSpace(connectionId) && !validIds.Contains(connectionId))
        {
            return "The selected voice connection isn’t a samplehost Voice API (Call Control) application — it looks like a TeXML or SIP connection. samplehost automatically makes a TeXML app when an AI Assistant enables telephony, but outbound calls require a Voice API application.";
        }
        if (selectedNumber != null
            && !string.IsNullOrWhiteSpace(selectedNumber.ConnectionId)
            && !validIds.Contains(selectedNumber.ConnectionId!)
            && string.IsNullOrWhiteSpace(connectionId))
        {
            var label = string.IsNullOrWhiteSpace(selectedNumber.ConnectionName)
                ? "another connection"
                : $"“{selectedNumber.ConnectionName}”";
            return $"{PhoneFormatting.FormatShown(selectedNumber.PhoneNumber)} is currently assigned to {label} in samplehost, which is a TeXML or SIP connection rather than a Voice API (Call Control) application. Choose or create a Voice API connection below.";
        }
        return null;
    }
}

/// `ask_owner` tool contract allowing the live AI caller to pause and ask the user a question mid-call.
public static class PhoneAskOwner
{
    public const string ToolName = "ask_owner";
    public const string AssistantName = "Hermes HQ Caller";
    public const string StoredGreeting = "";

    public static JsonObject RecommendedTranscription() => new()
    {
        ["model"] = "deepgram/flux",
        ["language"] = "auto",
        ["settings"] = new JsonObject
        {
            ["eot_threshold"] = 0.55,
            ["eager_eot_threshold"] = 0.35,
            ["eot_timeout_ms"] = 3000,
        },
    };

    public static JsonObject RecommendedInterruption() => new()
    {
        ["enable"] = true,
        ["disable_greeting_interruption"] = false,
        ["interrupt_prediction_threshold"] = 0.4,
    };

    public static JsonObject RecommendedTelephony(bool recording) => new()
    {
        ["noise_suppression"] = "aicoustics",
        ["greeting_delay_ms"] = 400,
        ["time_limit_secs"] = PhoneLimits.MaxCallSeconds,
        ["user_idle_timeout_secs"] = 180,
        ["user_idle_reply_secs"] = 5,
        ["recording_settings"] = new JsonObject { ["enabled"] = recording },
    };

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
            ["url"] = PhoneLimits.AskOwnerUrl,
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
