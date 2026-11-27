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

    public async Task<IReadOnlyList<samplehostNumber>> PhoneNumbersAsync(string apiKey, CancellationToken ct = default)
    {
        var json = await SendJsonAsync(apiKey, HttpMethod.Get, "phone_numbers?page[size]=50", null, null, ct);
        return ParseNumbers(json.Arr("data")).Where(n => !string.IsNullOrEmpty(n.ConnectionId)).ToList();
    }

    public async Task<IReadOnlyList<samplehostNumber>> AllPhoneNumbersAsync(string apiKey, CancellationToken ct = default)
    {
        var json = await SendJsonAsync(apiKey, HttpMethod.Get, "phone_numbers?page[size]=50", null, null, ct);
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
            ["name"] = string.IsNullOrWhiteSpace(name) ? "Hermes Phone Assistant" : name.Trim(),
            ["model"] = "meta-llama/Meta-Llama-3.1-70B-Instruct",
            ["instructions"] = PhoneAskOwner.Instructions(ownerName),
            ["enabled_features"] = new JsonArray("telephony"),
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
        var features = (data.Arr("enabled_features") ?? []).Select(J.AsString).OfType<string>().ToHashSet(StringComparer.OrdinalIgnoreCase);
        var telephony = data.Obj("telephony_settings");
        var recording = telephony?.Bool("recording_enabled") ?? telephony?.Obj("recording")?.Bool("enabled") ?? false;
        return new samplehostAssistantDetail(
            Id: id,
            Name: data.Text("name") ?? "Phone Assistant",
            Model: data.Text("model"),
            TelephonyEnabled: features.Contains("telephony") || telephony != null,
            RecordingEnabled: recording,
            Voice: data.Obj("voice_settings").Text("voice"));
    }

    public Task UpdateTelephonyAsync(string apiKey, string assistantId, bool enabled, CancellationToken ct = default)
    {
        var body = new JsonObject
        {
            ["enabled_features"] = enabled ? new JsonArray("telephony") : new JsonArray(),
        };
        return SendJsonAsync(apiKey, HttpMethod.Post, $"ai/assistants/{Uri.EscapeDataString(assistantId)}", body, null, ct);
    }

    public Task MatchRecordingAsync(string apiKey, string assistantId, bool recordCalls, CancellationToken ct = default)
    {
        var body = new JsonObject
        {
            ["telephony_settings"] = new JsonObject { ["recording_enabled"] = recordCalls },
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
        var json = await SendJsonAsync(apiKey, HttpMethod.Get, $"calls/{Uri.EscapeDataString(callControlId)}", null, null, ct);
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
            Active: data.Bool("active") ?? true);
    }

    public async Task<samplehostVoiceProfile?> VoiceProfileAsync(string apiKey, string profileId, CancellationToken ct = default)
    {
        var json = await SendJsonAsync(apiKey, HttpMethod.Get, $"outbound_voice_profiles/{Uri.EscapeDataString(profileId)}", null, null, ct);
        var data = json.Obj("data") ?? json as JsonObject;
        if (data?.Text("id") is not { } id) return null;
        var allowed = (data.Arr("whitelisted_destinations") ?? []).Select(J.AsString).OfType<string>().ToList();
        return new samplehostVoiceProfile(id, data.Text("name") ?? "Voice Profile", allowed, data.Bool("enabled") ?? true);
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
            {
                var detail = ExtractErrorDetail(raw, apiKey);
                var kind = resp.StatusCode switch
                {
                    HttpStatusCode.Unauthorized => samplehostErrorKind.Unauthorized,
                    HttpStatusCode.Forbidden => samplehostErrorKind.Forbidden,
                    HttpStatusCode.NotFound => samplehostErrorKind.NotFound,
                    HttpStatusCode.PaymentRequired => samplehostErrorKind.PaymentRequired,
                    HttpStatusCode.TooManyRequests => samplehostErrorKind.RateLimited,
                    >= HttpStatusCode.InternalServerError => samplehostErrorKind.ServerError,
                    _ => samplehostErrorKind.HttpError,
                };
                throw new samplehostException(kind, detail ?? $"samplehost answered {(int)resp.StatusCode}.", (int)resp.StatusCode);
            }

            if (string.IsNullOrWhiteSpace(raw)) return null;
            return J.Parse(raw);
        }
    }

    private static string? ExtractErrorDetail(string raw, string apiKey)
    {
        var parsed = J.Parse(raw);
        var first = parsed.Arr("errors")?.FirstOrDefault();
        var detail = first.Text("detail") ?? first.Text("title") ?? parsed.Text("detail") ?? parsed.Text("message");
        return detail != null ? PhoneMessages.Redact(detail, apiKey) : null;
    }

    private static IReadOnlyList<samplehostNumber> ParseNumbers(JsonArray? arr)
    {
        var list = new List<samplehostNumber>();
        foreach (var item in arr ?? [])
        {
            var phone = item.Text("phone_number");
            if (phone == null) continue;
            list.Add(new samplehostNumber(phone, item.Text("connection_id"), item.Text("connection_name"), item.Text("status")));
        }
        return list;
    }
}
