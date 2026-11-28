using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json.Nodes;

namespace Hermes.Core.PhoneCalls;

/// Direct samplehost v2 signaling contract (`App/PhoneCalls/samplehostClient.swift` port).
public interface IsamplehostApi
{
    Task<IReadOnlyList<samplehostNumber>> PhoneNumbersAsync(string apiKey, CancellationToken ct = default);
    Task<IReadOnlyList<samplehostNumber>> AllPhoneNumbersAsync(string apiKey, CancellationToken ct = default);
    Task<IReadOnlyList<samplehostAssistant>> AssistantsAsync(string apiKey, CancellationToken ct = default);
    Task<samplehostAssistant> CreateAssistantAsync(string apiKey, string name, string ownerName, string? voice = null, CancellationToken ct = default);
    Task<samplehostAssistantDetail?> AssistantAsync(string apiKey, string assistantId, CancellationToken ct = default);
    Task UpdateTelephonyAsync(string apiKey, string assistantId, bool enabled, CancellationToken ct = default);
    Task MatchRecordingAsync(string apiKey, string assistantId, bool recordCalls, CancellationToken ct = default);
    Task<samplehostDialed> DialAsync(string apiKey, PhoneDialRequest request, CancellationToken ct = default);
    Task<string?> ConversationIdAsync(string apiKey, string callControlId, CancellationToken ct = default);
    Task<IReadOnlyList<samplehostMessage>> MessagesAsync(string apiKey, string conversationId, CancellationToken ct = default);
    Task<samplehostConversationInsight?> ConversationSummaryAsync(string apiKey, string conversationId, CancellationToken ct = default);
    Task DeliverAnswerAsync(string apiKey, string conversationId, string toolCallId, string answer, CancellationToken ct = default);
    Task SendOwnerMessageAsync(string apiKey, string conversationId, string text, CancellationToken ct = default);
    Task SetMuteAsync(string apiKey, string callControlId, bool muted, CancellationToken ct = default);
    Task SetHoldAsync(string apiKey, string callControlId, bool onHold, CancellationToken ct = default);
    Task HangupAsync(string apiKey, string callControlId, CancellationToken ct = default);
    Task<samplehostCallStatus?> CallStatusAsync(string apiKey, string callControlId, CancellationToken ct = default);
    Task<IReadOnlyList<PhoneCallEvent>> CallEventsAsync(string apiKey, string callLegId, CancellationToken ct = default);
    Task<samplehostBalance?> BalanceAsync(string apiKey, CancellationToken ct = default);
    Task<samplehostCallControlApp?> CallControlAppAsync(string apiKey, string connectionId, CancellationToken ct = default);
    Task<samplehostVoiceProfile?> VoiceProfileAsync(string apiKey, string profileId, CancellationToken ct = default);

    // samplehost setup guidance & provisioning endpoints (default implementations preserve test-double compatibility).
    Task<IReadOnlyList<samplehostCallControlAppSummary>> CallControlAppsAsync(string apiKey, CancellationToken ct = default) =>
        Task.FromResult<IReadOnlyList<samplehostCallControlAppSummary>>([]);

    Task<IReadOnlyList<samplehostVoiceProfile>> VoiceProfilesAsync(string apiKey, CancellationToken ct = default) =>
        Task.FromResult<IReadOnlyList<samplehostVoiceProfile>>([]);

    Task<samplehostVoiceProfile> CreateVoiceProfileAsync(
        string apiKey,
        string name = PhoneLimits.VoiceProfileName,
        string country = "US",
        CancellationToken ct = default) =>
        throw new NotSupportedException("CreateVoiceProfileAsync is not implemented by this IsamplehostApi.");

    Task<string> EnsureVoiceProfileAsync(string apiKey, string country = "US", CancellationToken ct = default) =>
        throw new NotSupportedException("EnsureVoiceProfileAsync is not implemented by this IsamplehostApi.");

    Task<samplehostCallControlAppSummary> CreateCallControlAppAsync(
        string apiKey,
        string outboundProfileId,
        string name = PhoneLimits.VoiceAppName,
        string webhookUrl = PhoneLimits.VoiceWebhookUrl,
        CancellationToken ct = default) =>
        throw new NotSupportedException("CreateCallControlAppAsync is not implemented by this IsamplehostApi.");

    Task<samplehostCallControlApp> UpdateCallControlAppAsync(
        string apiKey,
        string id,
        string name,
        string webhookUrl,
        string outboundProfileId,
        CancellationToken ct = default) =>
        throw new NotSupportedException("UpdateCallControlAppAsync is not implemented by this IsamplehostApi.");

    Task<samplehostNumber> AssignNumberConnectionAsync(
        string apiKey,
        string numberId,
        string connectionId,
        CancellationToken ct = default) =>
        throw new NotSupportedException("AssignNumberConnectionAsync is not implemented by this IsamplehostApi.");

    Task<(samplehostCallControlAppSummary App, samplehostNumber? UpdatedNumber)> ProvisionVoiceConnectionAsync(
        string apiKey,
        samplehostNumber? number,
        string webhookUrl = PhoneLimits.VoiceWebhookUrl,
        CancellationToken ct = default) =>
        throw new NotSupportedException("ProvisionVoiceConnectionAsync is not implemented by this IsamplehostApi.");

    Task<(string ConnectionId, string ConnectionName, samplehostNumber? UpdatedNumber)> RepairVoiceConnectionAsync(
        string apiKey,
        string? connectionId,
        samplehostNumber? number,
        string webhookUrl = PhoneLimits.VoiceWebhookUrl,
        CancellationToken ct = default) =>
        throw new NotSupportedException("RepairVoiceConnectionAsync is not implemented by this IsamplehostApi.");

    Task PrepareAssistantForCallAsync(string apiKey, string assistantId, bool recording, CancellationToken ct = default) =>
        MatchRecordingAsync(apiKey, assistantId, recording, ct);

    Task OptimizeAssistantAsync(string apiKey, string assistantId, bool recording, CancellationToken ct = default) =>
        MatchRecordingAsync(apiKey, assistantId, recording, ct);
}

/// Live samplehost v2 REST client. Never follows redirects, enforces `samplehostEndpoint.IsAllowed`, and redacts keys.
public sealed class samplehostApi : IsamplehostApi, IDisposable
{
    private readonly HttpClient _http;
    private readonly Uri _baseUri;
    private readonly bool _ownsClient;

    public samplehostApi(Uri? baseUri = null, bool allowLoopback = false, HttpMessageHandler? handler = null)
    {
        var target = baseUri ?? samplehostEndpoint.Production;
        if (!samplehostEndpoint.IsAllowed(target, allowLoopback))
            throw new samplehostException(samplehostErrorKind.RejectedHost, "Refused to connect samplehost client to a non-samplehost host.");

        _baseUri = new Uri(target.AbsoluteUri.TrimEnd('/') + "/");
        if (handler != null)
        {
            _http = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(25) };
            _ownsClient = true;
        }
        else
        {
            _http = new HttpClient(new SocketsHttpHandler
            {
                AllowAutoRedirect = false,
                ConnectTimeout = TimeSpan.FromSeconds(15),
            })
            { Timeout = TimeSpan.FromSeconds(25) };
            _ownsClient = true;
        }
    }

    public void Dispose()
    {
        if (_ownsClient) _http.Dispose();
    }

    /// True when `raw` is an `https://` URL with a dotted host, as samplehost requires on Call Control `webhook_event_url`.
    public static bool HasValidWebhookUrl(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return false;
        var trimmed = raw.Trim();
        if (trimmed.Any(char.IsWhiteSpace)) return false;
        return Uri.TryCreate(trimmed, UriKind.Absolute, out var uri)
            && string.Equals(uri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase)
            && !string.IsNullOrEmpty(uri.Host)
            && uri.Host.Contains('.', StringComparison.Ordinal);
    }

    public async Task<IReadOnlyList<samplehostNumber>> PhoneNumbersAsync(string apiKey, CancellationToken ct = default)
    {
        var json = await SendJsonAsync(apiKey, HttpMethod.Get, "phone_numbers?page[size]=250", null, null, ct);
        return ParseNumbers(json.Arr("data"))
            .Where(n => n.Status == null || string.Equals(n.Status, "active", StringComparison.OrdinalIgnoreCase))
            .ToList();
    }

    public async Task<IReadOnlyList<samplehostNumber>> AllPhoneNumbersAsync(string apiKey, CancellationToken ct = default)
    {
        var json = await SendJsonAsync(apiKey, HttpMethod.Get, "phone_numbers?page[size]=250", null, null, ct);
        return ParseNumbers(json.Arr("data"));
    }

    public async Task<IReadOnlyList<samplehostAssistant>> AssistantsAsync(string apiKey, CancellationToken ct = default)
    {
        var json = await SendJsonAsync(apiKey, HttpMethod.Get, "ai/assistants", null, null, ct);
        var list = new List<samplehostAssistant>();
        foreach (var item in json.Arr("data") ?? [])
        {
            var id = item.Text("id");
            if (id == null) continue;
            list.Add(new samplehostAssistant(id, item.Text("name") ?? "Phone Assistant", item.Text("model"), item.Obj("voice_settings").Text("voice")));
        }
        return list;
    }

    public async Task<samplehostAssistant> CreateAssistantAsync(string apiKey, string name, string ownerName, string? voice = null, CancellationToken ct = default)
    {
        var body = new JsonObject
        {
            ["name"] = string.IsNullOrWhiteSpace(name) ? PhoneAskOwner.AssistantName : name.Trim(),
            ["model"] = "meta-llama/Meta-Llama-3.1-70B-Instruct",
            ["instructions"] = PhoneAskOwner.Instructions(ownerName),
            ["greeting"] = PhoneAskOwner.StoredGreeting,
            ["enabled_features"] = new JsonArray("telephony"),
            ["transcription"] = PhoneAskOwner.RecommendedTranscription(),
            ["interruption_settings"] = PhoneAskOwner.RecommendedInterruption(),
            ["telephony_settings"] = PhoneAskOwner.RecommendedTelephony(recording: false),
            ["tools"] = new JsonArray(PhoneAskOwner.ToolDefinition()),
        };
        if (!string.IsNullOrWhiteSpace(voice))
            body["voice_settings"] = new JsonObject { ["voice"] = voice.Trim() };

        var json = await SendJsonAsync(apiKey, HttpMethod.Post, "ai/assistants", body, null, ct);
        var data = json.Obj("data") ?? json as JsonObject;
        var id = data.Text("id") ?? throw new samplehostException(samplehostErrorKind.InvalidResponse, "samplehost did not return an assistant id.");
        return new samplehostAssistant(id, data.Text("name") ?? name, data.Text("model"), data.Obj("voice_settings").Text("voice"));
    }

    public async Task<samplehostAssistantDetail?> AssistantAsync(string apiKey, string assistantId, CancellationToken ct = default)
    {
        var json = await SendJsonAsync(apiKey, HttpMethod.Get, $"ai/assistants/{Uri.EscapeDataString(assistantId)}", null, null, ct);
        var data = json.Obj("data") ?? json as JsonObject;
        if (data?.Text("id") is not { } id) return null;
        var features = (data.Arr("enabled_features") ?? []).Select(J.AsString).OfType<string>().ToList();
        var featureSet = features.ToHashSet(StringComparer.OrdinalIgnoreCase);
        var telephony = data.Obj("telephony_settings");
        var recording = telephony?.Obj("recording_settings")?.Bool("enabled")
            ?? telephony?.Bool("recording_enabled")
            ?? telephony?.Obj("recording")?.Bool("enabled")
            ?? (telephony != null);
        return new samplehostAssistantDetail(
            Id: id,
            Name: data.Text("name") ?? "Phone Assistant",
            Model: data.Text("model"),
            TelephonyEnabled: featureSet.Contains("telephony") || telephony != null,
            RecordingEnabled: recording,
            Voice: data.Obj("voice_settings").Text("voice"),
            TranscriptionModel: data.Obj("transcription").Text("model"),
            InterruptionEnabled: data.Obj("interruption_settings")?.Bool("enable"),
            UserIdleTimeoutSecs: (int?)telephony?.Int("user_idle_timeout_secs"),
            UserIdleReplySecs: (int?)telephony?.Int("user_idle_reply_secs"),
            GreetingDelayMs: (int?)telephony?.Int("greeting_delay_ms"),
            NoiseSuppression: telephony.Text("noise_suppression"),
            Greeting: data.Str("greeting"),
            EnabledFeatures: features,
            TelephonySettingsJson: telephony?.ToJsonString());
    }

    public Task UpdateTelephonyAsync(string apiKey, string assistantId, bool enabled, CancellationToken ct = default)
    {
        var body = new JsonObject
        {
            ["enabled_features"] = enabled ? new JsonArray("telephony") : new JsonArray(),
        };
        return SendJsonAsync(apiKey, HttpMethod.Post, $"ai/assistants/{Uri.EscapeDataString(assistantId)}", body, null, ct);
    }

    public async Task MatchRecordingAsync(string apiKey, string assistantId, bool recordCalls, CancellationToken ct = default)
    {
        JsonObject? telephony = null;
        try
        {
            var detail = await AssistantAsync(apiKey, assistantId, ct);
            if (detail?.TelephonySettingsJson is { Length: > 0 } raw)
                telephony = J.Parse(raw) as JsonObject;
        }
        catch (samplehostException) { }

        telephony ??= new JsonObject();
        var rec = telephony["recording_settings"] as JsonObject ?? new JsonObject();
        rec["enabled"] = recordCalls;
        telephony["recording_settings"] = rec;
        telephony["recording_enabled"] = recordCalls;
        var body = new JsonObject { ["telephony_settings"] = telephony };
        await SendJsonAsync(apiKey, HttpMethod.Post, $"ai/assistants/{Uri.EscapeDataString(assistantId)}", body, null, ct);
    }

    /// Prepares the assistant before dialing: guarantees `recording_settings.enabled` matches `recording` (failing
    /// strictly if it cannot), and upgrades suboptimal call quality settings on a best-effort basis.
    public async Task PrepareAssistantForCallAsync(string apiKey, string assistantId, bool recording, CancellationToken ct = default)
    {
        var detail = await AssistantAsync(apiKey, assistantId, ct)
            ?? throw new samplehostException(samplehostErrorKind.NotFound, "The chosen assistant isn’t on this samplehost account.", 404);
        if (detail.TelephonySettingsJson == null)
            throw new samplehostException(samplehostErrorKind.HttpError, "The assistant has no telephony settings. Turn on telephony for it in the samplehost portal.");

        var needsRecording = detail.RecordingEnabled != recording;
        var needsQuality = detail.CallQualityIssues.Count > 0;
        if (!needsRecording && !needsQuality) return;

        if (needsQuality)
        {
            try
            {
                await ApplyOptimizationAsync(apiKey, detail, assistantId, recording, ct);
                return;
            }
            catch (samplehostException) when (!needsRecording)
            {
                return;
            }
            catch (samplehostException) { }
        }

        var telephony = J.Parse(detail.TelephonySettingsJson) as JsonObject ?? new JsonObject();
        var rec = telephony["recording_settings"] as JsonObject ?? new JsonObject();
        rec["enabled"] = recording;
        telephony["recording_settings"] = rec;
        await SendJsonAsync(apiKey, HttpMethod.Post, $"ai/assistants/{Uri.EscapeDataString(assistantId)}",
            new JsonObject { ["telephony_settings"] = telephony }, null, ct);
    }

    /// Upgrades an existing assistant with fluid telephony defaults (`deepgram/flux`, `aicoustics` noise suppression,
    /// `greeting_delay_ms: 400`, `interruption_settings`, `user_idle_reply_secs: 5`) while preserving existing
    /// `telephony_settings` keys (such as `default_texml_app_id`).
    public async Task OptimizeAssistantAsync(string apiKey, string assistantId, bool recording, CancellationToken ct = default)
    {
        var detail = await AssistantAsync(apiKey, assistantId, ct)
            ?? throw new samplehostException(samplehostErrorKind.NotFound, "The chosen assistant isn’t on this samplehost account.", 404);
        await ApplyOptimizationAsync(apiKey, detail, assistantId, recording, ct);
    }

    private Task ApplyOptimizationAsync(string apiKey, samplehostAssistantDetail detail, string assistantId, bool recording, CancellationToken ct)
    {
        var features = new List<string>(detail.EnabledFeatures ?? []);
        if (!features.Contains("telephony", StringComparer.OrdinalIgnoreCase)) features.Add("telephony");
        var featuresArr = new JsonArray();
        foreach (var f in features) featuresArr.Add(f);

        var telephony = (detail.TelephonySettingsJson is { Length: > 0 } raw ? J.Parse(raw) as JsonObject : null) ?? new JsonObject();
        telephony["noise_suppression"] = "aicoustics";
        telephony["greeting_delay_ms"] = 400;
        telephony["time_limit_secs"] = PhoneLimits.MaxCallSeconds;
        telephony["user_idle_timeout_secs"] = 180;
        telephony["user_idle_reply_secs"] = 5;
        var rec = telephony["recording_settings"] as JsonObject ?? new JsonObject();
        rec["enabled"] = recording;
        telephony["recording_settings"] = rec;

        var body = new JsonObject
        {
            ["enabled_features"] = featuresArr,
            ["greeting"] = PhoneAskOwner.StoredGreeting,
            ["transcription"] = PhoneAskOwner.RecommendedTranscription(),
            ["interruption_settings"] = PhoneAskOwner.RecommendedInterruption(),
            ["telephony_settings"] = telephony,
        };
        return SendJsonAsync(apiKey, HttpMethod.Post, $"ai/assistants/{Uri.EscapeDataString(assistantId)}", body, null, ct);
    }

    public async Task<samplehostDialed> DialAsync(string apiKey, PhoneDialRequest request, CancellationToken ct = default)
    {
        var voicemailDirective = request.Voicemail == PhoneVoicemailChoice.LeaveMessage
            ? "If you reach voicemail, leave a concise voicemail explaining the reason for the call and a callback number."
            : "If you reach voicemail, hang up without leaving a message.";

        var goalPrompt = $"Goal: {request.Goal.Trim()}\n{voicemailDirective}";
        var body = new JsonObject
        {
            ["to"] = request.To,
            ["from"] = request.From,
            ["connection_id"] = request.ConnectionId,
            ["answering_machine_detection"] = "detect",
            ["ai_assistant"] = new JsonObject
            {
                ["id"] = request.AssistantId,
                ["instructions"] = PhoneAskOwner.Instructions(request.OwnerName) + "\n\n" + goalPrompt,
            },
        };
        if (request.Record) body["record"] = "record-from-answer";
        var headers = new Dictionary<string, string> { ["Idempotency-Key"] = request.IdempotencyKey };
        var json = await SendJsonAsync(apiKey, HttpMethod.Post, "calls", body, headers, ct);
        var data = json.Obj("data") ?? json as JsonObject;
        var controlId = data.Text("call_control_id") ?? throw new samplehostException(samplehostErrorKind.InvalidResponse, "samplehost did not return a call_control_id.");
        var legId = data.Text("call_leg_id") ?? controlId;
        return new samplehostDialed(controlId, legId, data.Text("call_session_id"));
    }

    public async Task<string?> ConversationIdAsync(string apiKey, string callControlId, CancellationToken ct = default)
    {
        var json = await SendJsonAsync(apiKey, HttpMethod.Get,
            $"ai/conversations?filter[metadata.samplehost_call_control_id]={Uri.EscapeDataString(callControlId)}", null, null, ct);
        return json.Arr("data")?.FirstOrDefault()?.Text("id");
    }

    public async Task<IReadOnlyList<samplehostMessage>> MessagesAsync(string apiKey, string conversationId, CancellationToken ct = default)
    {
        var json = await SendJsonAsync(apiKey, HttpMethod.Get,
            $"ai/conversations/{Uri.EscapeDataString(conversationId)}/messages", null, null, ct);
        var list = new List<samplehostMessage>();
        var idx = 0;
        foreach (var item in json.Arr("data") ?? [])
        {
            var id = item.Text("id") ?? $"msg-{idx++}";
            var role = item.Text("role") ?? "assistant";
            var text = item.Str("text") ?? item.Str("content") ?? "";
            var createdAt = PhoneCallEvent.ParseTimestamp(item.Str("created_at"));
            var toolCalls = new List<samplehostToolCall>();
            foreach (var tc in item.Arr("tool_calls") ?? [])
            {
                var tcId = tc.Text("id") ?? "";
                var fn = tc.Obj("function");
                var name = fn.Text("name") ?? tc.Text("name") ?? "";
                var args = fn.Str("arguments") ?? tc.Str("arguments") ?? "{}";
                if (name.Length > 0) toolCalls.Add(new samplehostToolCall(tcId, name, args));
            }
            list.Add(new samplehostMessage(id, role, text, createdAt, toolCalls, item.Text("tool_call_id")));
        }
        return list;
    }

    public async Task<samplehostConversationInsight?> ConversationSummaryAsync(string apiKey, string conversationId, CancellationToken ct = default)
    {
        var json = await SendJsonAsync(apiKey, HttpMethod.Get,
            $"ai/conversations/{Uri.EscapeDataString(conversationId)}/conversations-insights", null, null, ct);
        var first = json.Arr("data")?.FirstOrDefault();
        var summary = first.Text("result") ?? first.Text("summary") ?? json.Obj("data").Text("summary");
        if (string.IsNullOrWhiteSpace(summary)) return null;
        return new samplehostConversationInsight(summary!, PhoneCallEvent.ParseTimestamp(first.Str("created_at")));
    }

    public Task DeliverAnswerAsync(string apiKey, string conversationId, string toolCallId, string answer, CancellationToken ct = default)
    {
        var body = new JsonObject
        {
            ["role"] = "tool",
            ["tool_call_id"] = toolCallId,
            ["content"] = answer,
        };
        return SendJsonAsync(apiKey, HttpMethod.Post, $"ai/conversations/{Uri.EscapeDataString(conversationId)}/message", body, null, ct);
    }

    public Task SendOwnerMessageAsync(string apiKey, string conversationId, string text, CancellationToken ct = default)
    {
        var body = new JsonObject
        {
            ["role"] = "system",
            ["content"] = $"Owner instruction: {text.Trim()}",
        };
        return SendJsonAsync(apiKey, HttpMethod.Post, $"ai/conversations/{Uri.EscapeDataString(conversationId)}/message", body, null, ct);
    }

    public Task SetMuteAsync(string apiKey, string callControlId, bool muted, CancellationToken ct = default)
    {
        var action = muted ? "mute" : "unmute";
        return SendJsonAsync(apiKey, HttpMethod.Post, $"calls/{Uri.EscapeDataString(callControlId)}/actions/{action}", new JsonObject(), null, ct);
    }

    public Task SetHoldAsync(string apiKey, string callControlId, bool onHold, CancellationToken ct = default)
    {
        var action = onHold ? "hold" : "unhold";
        return SendJsonAsync(apiKey, HttpMethod.Post, $"calls/{Uri.EscapeDataString(callControlId)}/actions/{action}", new JsonObject(), null, ct);
    }

    public Task HangupAsync(string apiKey, string callControlId, CancellationToken ct = default) =>
        SendJsonAsync(apiKey, HttpMethod.Post, $"calls/{Uri.EscapeDataString(callControlId)}/actions/hangup", new JsonObject(), null, ct);

    public async Task<samplehostCallStatus?> CallStatusAsync(string apiKey, string callControlId, CancellationToken ct = default)
    {
        JsonNode? json;
        try
        {
            json = await SendJsonAsync(apiKey, HttpMethod.Get, $"calls/{Uri.EscapeDataString(callControlId)}", null, null, ct);
        }
        catch (samplehostException ex) when (ex.IsNotFound)
        {
            // H6: HTTP 404 (empty or JSON error body) means samplehost no longer knows the call (ended).
            return null;
        }
        var data = json.Obj("data") ?? json as JsonObject;
        if (data == null) return null;
        return new samplehostCallStatus(
            CallControlId: data.Text("call_control_id") ?? callControlId,
            IsAlive: data.Bool("is_alive") ?? false,
            State: data.Text("state") ?? (data.Bool("is_alive") == true ? "active" : "ended"),
            HangupCause: data.Text("hangup_cause"),
            AnsweredAt: PhoneCallEvent.ParseTimestamp(data.Str("answered_at")),
            EndedAt: PhoneCallEvent.ParseTimestamp(data.Str("ended_at")));
    }

    public async Task<IReadOnlyList<PhoneCallEvent>> CallEventsAsync(string apiKey, string callLegId, CancellationToken ct = default)
    {
        var json = await SendJsonAsync(apiKey, HttpMethod.Get,
            $"call_events?filter[leg_id]={Uri.EscapeDataString(callLegId)}&page[size]=50", null, null, ct);
        var list = new List<PhoneCallEvent>();
        foreach (var item in json.Arr("data") ?? [])
        {
            var type = item.Text("name") ?? item.Text("event_type") ?? "";
            if (type.Length == 0) continue;
            var meta = item.Obj("metadata") ?? item.Obj("payload");
            list.Add(new PhoneCallEvent(
                Type: type,
                At: PhoneCallEvent.ParseTimestamp(item.Str("event_timestamp") ?? item.Str("occurred_at")),
                HangupCause: meta.Text("hangup_cause") ?? item.Text("hangup_cause"),
                SipCode: meta.Text("sip_hangup_cause") ?? meta.Text("sip_code"),
                MachineResult: meta.Text("result") ?? meta.Text("machine_detection_result"),
                Summary: meta.Text("summary")));
        }
        return list;
    }

    public async Task<samplehostBalance?> BalanceAsync(string apiKey, CancellationToken ct = default)
    {
        var json = await SendJsonAsync(apiKey, HttpMethod.Get, "balance", null, null, ct);
        var data = json.Obj("data") ?? json as JsonObject;
        if (data?.Num("balance") is not { } num) return null;
        return new samplehostBalance((decimal)num, data.Text("currency") ?? "USD");
    }

    public async Task<IReadOnlyList<samplehostCallControlAppSummary>> CallControlAppsAsync(string apiKey, CancellationToken ct = default)
    {
        var json = await SendJsonAsync(apiKey, HttpMethod.Get, "call_control_applications?page[size]=250", null, null, ct);
        var list = new List<samplehostCallControlAppSummary>();
        foreach (var item in json.Arr("data") ?? [])
        {
            var id = item.Text("id");
            if (id == null) continue;
            var active = item.Bool("active");
            if (active == false) continue;
            list.Add(new samplehostCallControlAppSummary(
                Id: id,
                ApplicationName: item.Text("application_name"),
                Active: active,
                WebhookEventUrl: item.Text("webhook_event_url"),
                OutboundVoiceProfileId: item.Obj("outbound").Text("outbound_voice_profile_id")));
        }
        return list;
    }

    public async Task<samplehostCallControlApp?> CallControlAppAsync(string apiKey, string connectionId, CancellationToken ct = default)
    {
        var json = await SendJsonAsync(apiKey, HttpMethod.Get, $"call_control_applications/{Uri.EscapeDataString(connectionId)}", null, null, ct);
        var data = json.Obj("data") ?? json as JsonObject;
        if (data?.Text("id") is not { } id) return null;
        var outbound = data.Obj("outbound");
        return new samplehostCallControlApp(
            Id: id,
            Name: data.Text("application_name") ?? "Voice Connection",
            OutboundVoiceProfileId: outbound.Text("outbound_voice_profile_id"),
            Active: data.Bool("active") ?? true,
            WebhookEventUrl: data.Text("webhook_event_url"));
    }

    public async Task<IReadOnlyList<samplehostVoiceProfile>> VoiceProfilesAsync(string apiKey, CancellationToken ct = default)
    {
        var json = await SendJsonAsync(apiKey, HttpMethod.Get, "outbound_voice_profiles?page[size]=250", null, null, ct);
        var list = new List<samplehostVoiceProfile>();
        foreach (var item in json.Arr("data") ?? [])
        {
            var id = item.Text("id");
            if (id == null) continue;
            var allowed = (item.Arr("whitelisted_destinations") ?? []).Select(J.AsString).OfType<string>().ToList();
            list.Add(new samplehostVoiceProfile(id, item.Text("name") ?? "Voice Profile", allowed, item.Bool("enabled") ?? true));
        }
        return list;
    }

    public async Task<samplehostVoiceProfile?> VoiceProfileAsync(string apiKey, string profileId, CancellationToken ct = default)
    {
        var json = await SendJsonAsync(apiKey, HttpMethod.Get, $"outbound_voice_profiles/{Uri.EscapeDataString(profileId)}", null, null, ct);
        var data = json.Obj("data") ?? json as JsonObject;
        if (data?.Text("id") is not { } id) return null;
        var allowed = (data.Arr("whitelisted_destinations") ?? []).Select(J.AsString).OfType<string>().ToList();
        return new samplehostVoiceProfile(id, data.Text("name") ?? "Voice Profile", allowed, data.Bool("enabled") ?? true);
    }

    public async Task<samplehostVoiceProfile> CreateVoiceProfileAsync(
        string apiKey,
        string name = PhoneLimits.VoiceProfileName,
        string country = "US",
        CancellationToken ct = default)
    {
        var normalized = string.IsNullOrWhiteSpace(country) ? "US" : country.Trim().ToUpperInvariant();
        var withDestinations = new JsonObject
        {
            ["name"] = string.IsNullOrWhiteSpace(name) ? PhoneLimits.VoiceProfileName : name.Trim(),
            ["traffic_type"] = "conversational",
            ["enabled"] = true,
            ["whitelisted_destinations"] = new JsonArray(normalized),
        };
        JsonNode? json;
        try
        {
            json = await SendJsonAsync(apiKey, HttpMethod.Post, "outbound_voice_profiles", withDestinations, null, ct);
        }
        catch (samplehostException)
        {
            // Fallback if a restricted account tier rejects explicit destination whitelisting on creation.
            var fallback = new JsonObject
            {
                ["name"] = string.IsNullOrWhiteSpace(name) ? PhoneLimits.VoiceProfileName : name.Trim(),
                ["traffic_type"] = "conversational",
                ["enabled"] = true,
            };
            json = await SendJsonAsync(apiKey, HttpMethod.Post, "outbound_voice_profiles", fallback, null, ct);
        }
        var data = json.Obj("data") ?? json as JsonObject;
        var id = data.Text("id") ?? throw new samplehostException(samplehostErrorKind.InvalidResponse, "samplehost did not return an outbound voice profile id.");
        var allowed = (data.Arr("whitelisted_destinations") ?? []).Select(J.AsString).OfType<string>().ToList();
        return new samplehostVoiceProfile(id, data.Text("name") ?? name, allowed, data.Bool("enabled") ?? true);
    }

    public async Task<string> EnsureVoiceProfileAsync(string apiKey, string country = "US", CancellationToken ct = default)
    {
        var target = (country ?? "").Trim().ToUpperInvariant();
        IReadOnlyList<samplehostVoiceProfile> existing;
        try { existing = await VoiceProfilesAsync(apiKey, ct); }
        catch (samplehostException) { existing = []; }

        var match = existing.FirstOrDefault(p =>
            !string.IsNullOrWhiteSpace(p.Id)
            && p.Enabled
            && (p.WhitelistedDestinations.Count == 0
                || target.Length == 0
                || p.WhitelistedDestinations.Contains(target, StringComparer.OrdinalIgnoreCase)));
        if (match != null) return match.Id;

        try
        {
            var created = await CreateVoiceProfileAsync(apiKey, PhoneLimits.VoiceProfileName, target.Length == 0 ? "US" : target, ct);
            if (!string.IsNullOrWhiteSpace(created.Id)) return created.Id;
        }
        catch (samplehostException)
        {
            if (existing.FirstOrDefault(p => !string.IsNullOrWhiteSpace(p.Id) && p.Enabled) is { } anyEnabled)
                return anyEnabled.Id;
            throw;
        }
        throw new samplehostException(samplehostErrorKind.HttpError, "Couldn’t create an outbound voice profile in samplehost.");
    }

    public async Task<samplehostCallControlAppSummary> CreateCallControlAppAsync(
        string apiKey,
        string outboundProfileId,
        string name = PhoneLimits.VoiceAppName,
        string webhookUrl = PhoneLimits.VoiceWebhookUrl,
        CancellationToken ct = default)
    {
        var body = new JsonObject
        {
            ["application_name"] = string.IsNullOrWhiteSpace(name) ? PhoneLimits.VoiceAppName : name.Trim(),
            ["active"] = true,
            ["webhook_api_version"] = "2",
            ["webhook_event_url"] = webhookUrl,
            ["outbound"] = new JsonObject { ["outbound_voice_profile_id"] = outboundProfileId },
        };
        var json = await SendJsonAsync(apiKey, HttpMethod.Post, "call_control_applications", body, null, ct);
        var data = json.Obj("data") ?? json as JsonObject;
        var id = data.Text("id") ?? throw new samplehostException(samplehostErrorKind.InvalidResponse, "samplehost did not return a Call Control application id.");
        return new samplehostCallControlAppSummary(
            Id: id,
            ApplicationName: data.Text("application_name") ?? name,
            Active: data.Bool("active") ?? true,
            WebhookEventUrl: data.Text("webhook_event_url") ?? webhookUrl,
            OutboundVoiceProfileId: data.Obj("outbound").Text("outbound_voice_profile_id") ?? outboundProfileId);
    }

    public async Task<samplehostCallControlApp> UpdateCallControlAppAsync(
        string apiKey,
        string id,
        string name,
        string webhookUrl,
        string outboundProfileId,
        CancellationToken ct = default)
    {
        var body = new JsonObject
        {
            ["application_name"] = string.IsNullOrWhiteSpace(name) ? PhoneLimits.VoiceAppName : name.Trim(),
            ["active"] = true,
            ["webhook_api_version"] = "2",
            ["webhook_event_url"] = webhookUrl,
            ["outbound"] = new JsonObject { ["outbound_voice_profile_id"] = outboundProfileId },
        };
        var json = await SendJsonAsync(apiKey, HttpMethod.Patch, $"call_control_applications/{Uri.EscapeDataString(id)}", body, null, ct);
        var data = json.Obj("data") ?? json as JsonObject;
        return new samplehostCallControlApp(
            Id: data.Text("id") ?? id,
            Name: data.Text("application_name") ?? name,
            OutboundVoiceProfileId: data.Obj("outbound").Text("outbound_voice_profile_id") ?? outboundProfileId,
            Active: data.Bool("active") ?? true,
            WebhookEventUrl: data.Text("webhook_event_url") ?? webhookUrl);
    }

    public async Task<samplehostNumber> AssignNumberConnectionAsync(
        string apiKey,
        string numberId,
        string connectionId,
        CancellationToken ct = default)
    {
        var body = new JsonObject { ["connection_id"] = connectionId };
        var json = await SendJsonAsync(apiKey, HttpMethod.Patch, $"phone_numbers/{Uri.EscapeDataString(numberId)}", body, null, ct);
        var data = json.Obj("data") ?? json as JsonObject;
        return new samplehostNumber(
            PhoneNumber: data.Text("phone_number") ?? "",
            ConnectionId: data.Text("connection_id") ?? connectionId,
            ConnectionName: data.Text("connection_name"),
            Status: data.Text("status"),
            Id: data.Text("id") ?? numberId);
    }

    public async Task<(samplehostCallControlAppSummary App, samplehostNumber? UpdatedNumber)> ProvisionVoiceConnectionAsync(
        string apiKey,
        samplehostNumber? number,
        string webhookUrl = PhoneLimits.VoiceWebhookUrl,
        CancellationToken ct = default)
    {
        var country = PhoneSetupCheck.CountryOf(number?.PhoneNumber) ?? "US";
        var profileId = await EnsureVoiceProfileAsync(apiKey, country, ct);
        var app = await CreateCallControlAppAsync(apiKey, profileId, PhoneLimits.VoiceAppName, webhookUrl, ct);
        samplehostNumber? updatedNumber = null;
        if (number != null && !string.IsNullOrWhiteSpace(number.Id) && !string.Equals(number.ConnectionId, app.Id, StringComparison.Ordinal))
        {
            try { updatedNumber = await AssignNumberConnectionAsync(apiKey, number.Id!, app.Id, ct); }
            catch (samplehostException) { }
        }
        return (app, updatedNumber);
    }

    /// Repairs an existing voice connection (H15: explicit custom webhook URL overrides stale saved URL; default
    /// placeholder preserves an existing valid `https://` URL, otherwise falls back to `PhoneLimits.VoiceWebhookUrl`).
    public async Task<(string ConnectionId, string ConnectionName, samplehostNumber? UpdatedNumber)> RepairVoiceConnectionAsync(
        string apiKey,
        string? connectionId,
        samplehostNumber? number,
        string webhookUrl = PhoneLimits.VoiceWebhookUrl,
        CancellationToken ct = default)
    {
        var country = PhoneSetupCheck.CountryOf(number?.PhoneNumber) ?? "US";
        samplehostCallControlApp? existing = null;
        if (!string.IsNullOrWhiteSpace(connectionId))
        {
            try { existing = await CallControlAppAsync(apiKey, connectionId!, ct); }
            catch (samplehostException) { existing = null; }
        }

        if (existing != null)
        {
            var existingProfileId = existing.OutboundVoiceProfileId ?? "";
            string profileId;
            samplehostVoiceProfile? prof = null;
            if (!string.IsNullOrWhiteSpace(existingProfileId))
            {
                try { prof = await VoiceProfileAsync(apiKey, existingProfileId, ct); }
                catch (samplehostException) { prof = null; }
            }
            if (prof != null && prof.Enabled
                && (prof.WhitelistedDestinations.Count == 0
                    || prof.WhitelistedDestinations.Contains(country, StringComparer.OrdinalIgnoreCase)))
            {
                profileId = existingProfileId;
            }
            else
            {
                profileId = await EnsureVoiceProfileAsync(apiKey, country, ct);
            }

            var hasCustomWebhook = !string.Equals(webhookUrl, PhoneLimits.VoiceWebhookUrl, StringComparison.Ordinal)
                && HasValidWebhookUrl(webhookUrl);
            string effectiveWebhook;
            if (hasCustomWebhook)
                effectiveWebhook = webhookUrl;
            else if (HasValidWebhookUrl(existing.WebhookEventUrl))
                effectiveWebhook = existing.WebhookEventUrl!;
            else
                effectiveWebhook = webhookUrl;

            var name = string.IsNullOrWhiteSpace(existing.Name) ? PhoneLimits.VoiceAppName : existing.Name;
            await UpdateCallControlAppAsync(apiKey, existing.Id, name, effectiveWebhook, profileId, ct);
            samplehostNumber? updatedNumber = null;
            if (number != null && !string.IsNullOrWhiteSpace(number.Id) && !string.Equals(number.ConnectionId, existing.Id, StringComparison.Ordinal))
            {
                try { updatedNumber = await AssignNumberConnectionAsync(apiKey, number.Id!, existing.Id, ct); }
                catch (samplehostException) { }
            }
            return (existing.Id, name, updatedNumber);
        }

        // Not a Call Control app (e.g. TeXML/SIP): reuse a healthy Call Control app if available, else provision one.
        IReadOnlyList<samplehostCallControlAppSummary> existingApps;
        try { existingApps = await CallControlAppsAsync(apiKey, ct); }
        catch (samplehostException) { existingApps = []; }

        var ready = existingApps.FirstOrDefault(a => !PhoneConnectionResolver.NeedsFix(a));
        if (ready != null)
        {
            samplehostNumber? updatedNumber = null;
            if (number != null && !string.IsNullOrWhiteSpace(number.Id) && !string.Equals(number.ConnectionId, ready.Id, StringComparison.Ordinal))
            {
                try { updatedNumber = await AssignNumberConnectionAsync(apiKey, number.Id!, ready.Id, ct); }
                catch (samplehostException) { }
            }
            return (ready.Id, string.IsNullOrWhiteSpace(ready.ApplicationName) ? ready.Id : ready.ApplicationName!, updatedNumber);
        }

        var provisioned = await ProvisionVoiceConnectionAsync(apiKey, number, webhookUrl, ct);
        return (provisioned.App.Id,
            string.IsNullOrWhiteSpace(provisioned.App.ApplicationName) ? provisioned.App.Id : provisioned.App.ApplicationName!,
            provisioned.UpdatedNumber);
    }

    /// Maps an HTTP error status and samplehost/FastAPI JSON error body into a redacted `samplehostException` (H6).
    public static samplehostException BuildFailure(HttpStatusCode statusCode, string rawBody, string? apiKey)
    {
        var parsed = string.IsNullOrWhiteSpace(rawBody) ? null : J.Parse(rawBody);
        var errors = parsed.Arr("errors");
        if (errors != null && errors.Any(e => string.Equals(e.Text("code") ?? e.Int("code")?.ToString(), "90018", StringComparison.Ordinal)))
            return new samplehostException(samplehostErrorKind.CallEnded, "This call has already ended.", (int)statusCode);

        var detail = ExtractErrorDetail(parsed, apiKey);
        var kind = statusCode switch
        {
            HttpStatusCode.Unauthorized => samplehostErrorKind.Unauthorized,
            HttpStatusCode.Forbidden => samplehostErrorKind.Forbidden,
            HttpStatusCode.NotFound => samplehostErrorKind.NotFound,
            HttpStatusCode.PaymentRequired => samplehostErrorKind.PaymentRequired,
            HttpStatusCode.TooManyRequests => samplehostErrorKind.RateLimited,
            >= HttpStatusCode.InternalServerError => samplehostErrorKind.ServerError,
            _ => samplehostErrorKind.HttpError,
        };
        var message = detail ?? $"samplehost answered {(int)statusCode}.";
        return new samplehostException(kind, PhoneMessages.Redact(message, apiKey), (int)statusCode);
    }

    private async Task<JsonNode?> SendJsonAsync(
        string apiKey,
        HttpMethod method,
        string relativePath,
        JsonObject? body,
        IReadOnlyDictionary<string, string>? extraHeaders,
        CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(apiKey))
            throw new samplehostException(samplehostErrorKind.NoKey, "samplehost API key is missing.");

        var uri = new Uri(_baseUri, relativePath);
        using var req = new HttpRequestMessage(method, uri);
        req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey.Trim());
        req.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        if (extraHeaders != null)
        {
            foreach (var (k, v) in extraHeaders) req.Headers.TryAddWithoutValidation(k, v);
        }
        if (body != null)
            req.Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json");

        HttpResponseMessage resp;
        try
        {
            resp = await _http.SendAsync(req, ct);
        }
        catch (HttpRequestException ex)
        {
            throw new samplehostException(samplehostErrorKind.Network, PhoneMessages.Redact(ex.Message, apiKey), null, ex);
        }

        using (resp)
        {
            var raw = await resp.Content.ReadAsStringAsync(ct);
            if ((int)resp.StatusCode is >= 300 and < 400)
                throw new samplehostException(samplehostErrorKind.RejectedHost, "samplehost returned an unexpected redirect.", (int)resp.StatusCode);

            if (!resp.IsSuccessStatusCode)
                throw BuildFailure(resp.StatusCode, raw, apiKey);

            if (string.IsNullOrWhiteSpace(raw)) return null;
            return J.Parse(raw);
        }
    }

    private static string? ExtractErrorDetail(JsonNode? parsed, string? apiKey)
    {
        if (parsed == null) return null;
        var words = new List<string>();
        foreach (var err in parsed.Arr("errors") ?? [])
        {
            var piece = err.Text("detail") ?? err.Text("title");
            if (!string.IsNullOrWhiteSpace(piece)) words.Add(piece!.Trim());
        }
        if (words.Count == 0 && parsed.Text("detail") is { Length: > 0 } strDetail)
            words.Add(strDetail.Trim());
        if (words.Count == 0)
        {
            foreach (var item in parsed.Arr("detail") ?? [])
            {
                var msg = item.Text("msg");
                if (!string.IsNullOrWhiteSpace(msg)) words.Add(msg!.Trim());
            }
        }
        if (words.Count == 0 && parsed.Text("message") is { Length: > 0 } msgField)
            words.Add(msgField.Trim());
        if (words.Count == 0) return null;
        var combined = PhoneMessages.Redact(string.Join(" ", words), apiKey);
        return combined.Length > 300 ? combined[..300] : combined;
    }

    private static IReadOnlyList<samplehostNumber> ParseNumbers(JsonArray? arr)
    {
        var list = new List<samplehostNumber>();
        foreach (var item in arr ?? [])
        {
            var phone = item.Text("phone_number");
            if (phone == null) continue;
            list.Add(new samplehostNumber(
                PhoneNumber: phone,
                ConnectionId: item.Text("connection_id"),
                ConnectionName: item.Text("connection_name"),
                Status: item.Text("status"),
                Id: item.Text("id")));
        }
        return list;
    }
}
