using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Hermes.Core.Net;

namespace Hermes.Core.Voice;

// Port of HermesKit/Voice/VoiceGateway.swift: REST & WebSocket endpoint helpers for
// voice config, speech-to-text, text-to-speech, GPT Live, and Grok Live sessions.

public sealed record SpeechClip(byte[] Audio, string Mime, string? Text = null);

public enum LeaseKind { Live, Grok }

public sealed record VoiceLease(
    string Token,
    Uri? Endpoint,
    string? Model,
    string? Voice,
    DateTimeOffset? ExpiresAt);

public abstract record SpeakStreamEvent
{
    public sealed record Audio(byte[] Data, string Mime) : SpeakStreamEvent;
    public sealed record Done : SpeakStreamEvent;
    public sealed record Error(string Message) : SpeakStreamEvent;
}

public static class VoiceWire
{
    public static readonly TimeSpan PhoneVoiceAfter = TimeSpan.FromSeconds(20);
    public static readonly TimeSpan TranscribeTimeout = TimeSpan.FromSeconds(120);
    public static readonly TimeSpan SpeakTimeout = TimeSpan.FromSeconds(45);

    public static readonly IReadOnlySet<string> PlayableMimes = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
    {
        "audio/mpeg",
        "audio/mp3",
        "audio/wav",
        "audio/x-wav",
        "audio/wave",
        "audio/mp4",
        "audio/x-m4a",
        "audio/aac",
        "audio/ogg",
        "audio/opus",
        "audio/flac",
        "audio/pcm",
    };

    public static bool IsPlayableMime(string? mime)
    {
        if (string.IsNullOrWhiteSpace(mime)) return false;
        var baseMime = mime.Split(';', 2)[0].Trim();
        return PlayableMimes.Contains(baseMime);
    }

    public static Uri SocketUrl(GatewayAddress address, string path, string ticket, string? profile = null)
    {
        var query = new List<KeyValuePair<string, string>>();
        if (!string.IsNullOrWhiteSpace(profile)) query.Add(new("profile", profile));
        query.Add(new("ticket", ticket));
        var http = address.Endpoint(path, query);
        var builder = new UriBuilder(http) { Scheme = http.Scheme == "https" ? "wss" : "ws" };
        if (http.IsDefaultPort) builder.Port = -1;
        return builder.Uri;
    }

    public static (byte[] Data, string Mime)? DecodeDataUrl(string? dataUrl)
    {
        if (string.IsNullOrWhiteSpace(dataUrl) || !dataUrl.StartsWith("data:", StringComparison.OrdinalIgnoreCase))
            return null;
        var comma = dataUrl.IndexOf(',');
        if (comma < 0) return null;
        var meta = dataUrl[5..comma];
        var payload = dataUrl[(comma + 1)..];
        var semi = meta.IndexOf(';');
        var mime = semi >= 0 ? meta[..semi].Trim() : meta.Trim();
        if (mime.Length == 0) mime = "audio/mpeg";
        if (!meta.Contains("base64", StringComparison.OrdinalIgnoreCase)) return null;
        try
        {
            var bytes = Convert.FromBase64String(payload);
            return bytes.Length > 0 ? (bytes, mime) : null;
        }
        catch (FormatException)
        {
            return null;
        }
    }

    public static SpeakStreamEvent? ParseSpeakStreamFrame(string json)
    {
        var node = J.Parse(json);
        if (node == null) return null;
        var type = node.Str("type") ?? "";
        switch (type)
        {
            case "audio" or "chunk":
                var b64 = node.Str("data") ?? node.Str("audio");
                if (string.IsNullOrWhiteSpace(b64)) return null;
                try
                {
                    var bytes = Convert.FromBase64String(b64);
                    var mime = node.Str("mime_type") ?? node.Str("mime") ?? "audio/mpeg";
                    return bytes.Length > 0 ? new SpeakStreamEvent.Audio(bytes, mime) : null;
                }
                catch (FormatException) { return null; }
            case "done" or "complete":
                return new SpeakStreamEvent.Done();
            case "error":
                return new SpeakStreamEvent.Error(node.Str("message") ?? node.Str("detail") ?? "Speech stream failed.");
            default:
                return null;
        }
    }

    public static VoiceLease? ParseLease(JsonNode? node)
    {
        if (node == null) return null;
        var token = node.Text("client_secret")
            ?? node.Get("client_secret")?.Text("value")
            ?? node.Text("token")
            ?? node.Text("ephemeral_key");
        if (string.IsNullOrWhiteSpace(token)) return null;
        Uri? endpoint = null;
        if ((node.Text("ws_url") ?? node.Text("url") ?? node.Text("endpoint")) is { } rawUrl
            && Uri.TryCreate(rawUrl, UriKind.Absolute, out var parsed))
            endpoint = parsed;
        var model = node.Text("model");
        var voice = node.Text("voice");
        var expiresAt = node.UnixTime("expires_at") ?? node.Get("client_secret")?.UnixTime("expires_at");
        return new VoiceLease(token, endpoint, model, voice, expiresAt);
    }
}

public interface IVoiceGateway
{
    Task<TalkConfig> ConfigAsync(string? profile, CancellationToken ct = default);
    Task<string> TranscribeAsync(byte[] audio, string mime, string? profile, CancellationToken ct = default);
    Task<SpeechClip> SpeakAsync(string text, string? voice, string? profile, CancellationToken ct = default);
    Task<LiveVoiceStatus> LiveStatusAsync(string? profile, CancellationToken ct = default);
    Task<VoiceLease> LiveSessionAsync(string? profile, string? voice, CancellationToken ct = default);
    Task<GrokLiveStatus> GrokStatusAsync(string? profile, CancellationToken ct = default);
    Task<GrokLiveSession> GrokSessionAsync(string? profile, string? voice, CancellationToken ct = default);
}

public sealed class VoiceGateway : IVoiceGateway
{
    private readonly IMemoTransfers _transfers;

    public VoiceGateway(IMemoTransfers transfers)
    {
        _transfers = transfers;
    }

    public VoiceGateway(HermesClient client) : this(client.MemoGateway) { }

    private static List<KeyValuePair<string, string>> ProfileQuery(string? profile) =>
        string.IsNullOrWhiteSpace(profile) ? [] : [new("profile", profile)];

    public async Task<TalkConfig> ConfigAsync(string? profile, CancellationToken ct = default)
    {
        var data = await _transfers.ConfigDataAsync(ProfileQuery(profile), TimeSpan.FromSeconds(10), ct);
        var json = J.Parse(Encoding.UTF8.GetString(data));
        return TalkConfig.Parse(json);
    }

    public async Task<string> TranscribeAsync(byte[] audio, string mime, string? profile, CancellationToken ct = default)
    {
        var cleanMime = string.IsNullOrWhiteSpace(mime) ? "audio/wav" : mime;
        var dataUrl = $"data:{cleanMime};base64,{Convert.ToBase64String(audio)}";
        var body = JsonSerializer.SerializeToUtf8Bytes(new JsonObject
        {
            ["data_url"] = dataUrl,
            ["mime_type"] = cleanMime,
        });
        var timeout = MemoUploader.TranscribeTimeout(Encoding.UTF8.GetByteCount(dataUrl));
        var data = await _transfers.TransferAsync("POST", "/api/audio/transcribe", ProfileQuery(profile), body,
            "application/json", timeout, ct);
        var json = J.Parse(Encoding.UTF8.GetString(data));
        if (json?.Bool("ok") == false)
        {
            var reason = json.Str("detail") ?? json.Str("error") ?? "The gateway could not transcribe the audio.";
            throw new GatewayException("http", reason, 422, Encoding.UTF8.GetString(data));
        }
        return VoiceMemo.TrimWhitespaceAndNewlines(json?.Str("transcript") ?? json?.Str("text") ?? "");
    }

    public async Task<SpeechClip> SpeakAsync(string text, string? voice, string? profile, CancellationToken ct = default)
    {
        var payload = new JsonObject { ["text"] = text };
        if (!string.IsNullOrWhiteSpace(voice)) payload["voice"] = voice;
        var body = JsonSerializer.SerializeToUtf8Bytes(payload);
        var data = await _transfers.TransferAsync("POST", "/api/audio/speak", ProfileQuery(profile), body,
            "application/json", VoiceWire.SpeakTimeout.TotalSeconds, ct);
        if (data.Length == 0) throw new GatewayException("http", "The gateway returned empty audio.", 204);

        // Some gateways return JSON containing data_url or audio base64; others return raw audio bytes.
        if (data[0] == (byte)'{')
        {
            var json = J.Parse(Encoding.UTF8.GetString(data));
            if (json?.Bool("ok") == false)
                throw new GatewayException("http", json.Str("detail") ?? json.Str("error") ?? "Couldn’t synthesize speech.", 500);
            if (VoiceWire.DecodeDataUrl(json?.Str("data_url")) is { } decoded)
                return new SpeechClip(decoded.Data, decoded.Mime, text);
            if (json?.Str("audio") is { Length: > 0 } b64)
                return new SpeechClip(Convert.FromBase64String(b64), json.Str("mime_type") ?? "audio/mpeg", text);
        }
        var mime = DetectAudioMime(data);
        return new SpeechClip(data, mime, text);
    }

    public async Task<LiveVoiceStatus> LiveStatusAsync(string? profile, CancellationToken ct = default)
    {
        var data = await _transfers.RestAsync("GET", "/api/voice/live/status", ProfileQuery(profile), null, ct);
        return LiveVoiceStatus.Parse(J.Parse(Encoding.UTF8.GetString(data)));
    }

    public async Task<VoiceLease> LiveSessionAsync(string? profile, string? voice, CancellationToken ct = default)
    {
        var payload = new JsonObject();
        if (!string.IsNullOrWhiteSpace(voice)) payload["voice"] = voice;
        var body = JsonSerializer.SerializeToUtf8Bytes(payload);
        var data = await _transfers.TransferAsync("POST", "/api/voice/live/session", ProfileQuery(profile), body,
            "application/json", 30, ct);
        var lease = VoiceWire.ParseLease(J.Parse(Encoding.UTF8.GetString(data)));
        return lease ?? throw new GatewayException("not-hermes", "The gateway didn’t return a live voice session.");
    }

    public async Task<GrokLiveStatus> GrokStatusAsync(string? profile, CancellationToken ct = default)
    {
        var data = await _transfers.RestAsync("GET", "/api/voice/grok/status", ProfileQuery(profile), null, ct);
        return GrokLiveStatus.Parse(J.Parse(Encoding.UTF8.GetString(data)));
    }

    public async Task<GrokLiveSession> GrokSessionAsync(string? profile, string? voice, CancellationToken ct = default)
    {
        var payload = new JsonObject();
        if (!string.IsNullOrWhiteSpace(voice)) payload["voice"] = voice;
        var body = JsonSerializer.SerializeToUtf8Bytes(payload);
        var data = await _transfers.TransferAsync("POST", "/api/voice/grok/session", ProfileQuery(profile), body,
            "application/json", 30, ct);
        var session = GrokLiveSession.Parse(J.Parse(Encoding.UTF8.GetString(data)));
        return session ?? throw new GatewayException("not-hermes", "The gateway didn’t return a Grok Live session.");
    }

    internal static string DetectAudioMime(byte[] bytes)
    {
        if (bytes.Length >= 4 && bytes[0] == 'R' && bytes[1] == 'I' && bytes[2] == 'F' && bytes[3] == 'F') return "audio/wav";
        if (bytes.Length >= 4 && bytes[0] == 'O' && bytes[1] == 'g' && bytes[2] == 'g' && bytes[3] == 'S') return "audio/ogg";
        if (bytes.Length >= 4 && bytes[0] == 'f' && bytes[1] == 'L' && bytes[2] == 'a' && bytes[3] == 'C') return "audio/flac";
        if (bytes.Length >= 8 && bytes[4] == 'f' && bytes[5] == 't' && bytes[6] == 'y' && bytes[7] == 'p') return "audio/mp4";
        return "audio/mpeg";
    }
}
