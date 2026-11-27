using System.Text;
using System.Text.Json.Nodes;

namespace Hermes.Core.Voice;

// Port of HermesKit/Voice/LiveVoiceWire.swift and GrokLiveWire.swift:
// OpenAI Realtime (GPT Live) and xAI Realtime (Grok Live) WebSocket framing, server event parsing,
// PCM chunking, conversation context packing, and ask_agent tool delegation.

public sealed record LiveVoiceStatus(
    bool Available,
    bool Configured,
    string? DefaultVoice = null,
    string? Model = null,
    string? Reason = null)
{
    public static readonly LiveVoiceStatus Unavailable = new(false, false);

    public static LiveVoiceStatus Parse(JsonNode? node)
    {
        if (node == null) return Unavailable;
        var available = node.Bool("available") ?? node.Bool("enabled") ?? false;
        var configured = node.Bool("configured") ?? available;
        return new LiveVoiceStatus(available, configured, node.Text("voice") ?? node.Text("default_voice"),
            node.Text("model"), node.Text("reason") ?? node.Text("detail"));
    }
}

public sealed record LiveTranscriptFragment(string ItemId, string Role, string Text, bool IsFinal);

public abstract record LiveServerEvent
{
    public sealed record SessionReady : LiveServerEvent;
    public sealed record SpeechStarted : LiveServerEvent;
    public sealed record SpeechStopped : LiveServerEvent;
    public sealed record UserTranscriptDelta(string Text) : LiveServerEvent;
    public sealed record UserTranscriptFinal(string Text) : LiveServerEvent;
    public sealed record AssistantAudioDelta(byte[] Pcm24k) : LiveServerEvent;
    public sealed record AssistantTextDelta(string Text) : LiveServerEvent;
    public sealed record AssistantDone(string? FullText) : LiveServerEvent;
    public sealed record FunctionCall(string CallId, string Name, string ArgumentsJson) : LiveServerEvent;
    public sealed record Error(string Message, bool Fatal) : LiveServerEvent;
    public sealed record Closed(string? Reason) : LiveServerEvent;
}

public static class LiveVoiceWire
{
    public const int PcmSampleRate = 24000;
    public const int DefaultChunkBytes = 4800; // 100 ms of 24 kHz 16-bit mono PCM
    public const string AskAgentToolName = "ask_agent";
    public const string EndVoiceToolName = "end_voice_conversation";

    public static string DelegationPrompt(string botName, string? context = null)
    {
        var sb = new StringBuilder();
        sb.Append($"You are speaking aloud as {botName} in a live voice conversation. ");
        sb.Append("Keep replies concise, natural, and spoken — avoid markdown, code fences, or bullet lists. ");
        sb.Append($"When the user asks you to run tools, read files, search, or take action on their computer, call `{AskAgentToolName}` and briefly tell them you are checking. ");
        sb.Append($"If the user asks to end or stop the voice conversation, call `{EndVoiceToolName}`.");
        if (!string.IsNullOrWhiteSpace(context))
        {
            sb.Append("\n\nRecent conversation context:\n");
            sb.Append(context.Trim());
        }
        return sb.ToString();
    }

    public static string BuildHistoryContext(IReadOnlyList<(string Role, string Text)> recent, int maxChars = 4000)
    {
        if (recent.Count == 0 || maxChars <= 0) return "";
        var lines = new List<string>();
        var total = 0;
        for (var i = recent.Count - 1; i >= 0; i--)
        {
            var (role, text) = recent[i];
            var clean = SpeechText.SanitizeForSpeech(text);
            if (clean.Length == 0) continue;
            var line = $"{role}: {clean}";
            if (total + line.Length + 1 > maxChars && lines.Count > 0) break;
            lines.Add(line);
            total += line.Length + 1;
        }
        lines.Reverse();
        return string.Join("\n", lines);
    }

    public static string SessionUpdate(string voice, string instructions, bool offerTools = true)
    {
        var session = new JsonObject
        {
            ["modalities"] = new JsonArray("text", "audio"),
            ["voice"] = string.IsNullOrWhiteSpace(voice) ? LiveVoices.DefaultGptVoice : voice,
            ["instructions"] = instructions,
            ["input_audio_format"] = "pcm16",
            ["output_audio_format"] = "pcm16",
            ["input_audio_transcription"] = new JsonObject { ["model"] = "whisper-1" },
            ["turn_detection"] = new JsonObject
            {
                ["type"] = "server_vad",
                ["threshold"] = 0.5,
                ["prefix_padding_ms"] = 300,
                ["silence_duration_ms"] = 700,
            },
        };
        if (offerTools)
        {
            session["tools"] = new JsonArray
            {
                new JsonObject
                {
                    ["type"] = "function",
                    ["name"] = AskAgentToolName,
                    ["description"] = "Delegate a task, tool call, code question, or file lookup to the full Hermes agent.",
                    ["parameters"] = new JsonObject
                    {
                        ["type"] = "object",
                        ["properties"] = new JsonObject
                        {
                            ["request"] = new JsonObject { ["type"] = "string", ["description"] = "What to ask the agent to do." },
                        },
                        ["required"] = new JsonArray("request"),
                    },
                },
                new JsonObject
                {
                    ["type"] = "function",
                    ["name"] = EndVoiceToolName,
                    ["description"] = "End the active voice conversation when the user asks to stop or hang up.",
                    ["parameters"] = new JsonObject
                    {
                        ["type"] = "object",
                        ["properties"] = new JsonObject(),
                    },
                },
            };
            session["tool_choice"] = "auto";
        }
        return new JsonObject { ["type"] = "session.update", ["session"] = session }.ToJsonString();
    }

    public static string AudioAppend(ReadOnlySpan<byte> pcm24kBytes) =>
        new JsonObject
        {
            ["type"] = "input_audio_buffer.append",
            ["audio"] = Convert.ToBase64String(pcm24kBytes),
        }.ToJsonString();

    public static string AudioCommit() => new JsonObject { ["type"] = "input_audio_buffer.commit" }.ToJsonString();
    public static string AudioClear() => new JsonObject { ["type"] = "input_audio_buffer.clear" }.ToJsonString();
    public static string ResponseCancel() => new JsonObject { ["type"] = "response.cancel" }.ToJsonString();
    public static string ResponseCreate() => new JsonObject { ["type"] = "response.create" }.ToJsonString();

    public static string FunctionCallOutput(string callId, string output) =>
        new JsonObject
        {
            ["type"] = "conversation.item.create",
            ["item"] = new JsonObject
            {
                ["type"] = "function_call_output",
                ["call_id"] = callId,
                ["output"] = output,
            },
        }.ToJsonString();

    public static IReadOnlyList<byte[]> ChunkPcm(ReadOnlySpan<byte> pcm, int chunkBytes = DefaultChunkBytes)
    {
        if (pcm.IsEmpty || chunkBytes <= 0) return [];
        var step = Math.Max(2, chunkBytes - (chunkBytes & 1));
        var chunks = new List<byte[]>((pcm.Length + step - 1) / step);
        for (var offset = 0; offset < pcm.Length; offset += step)
        {
            var len = Math.Min(step, pcm.Length - offset);
            chunks.Add(pcm.Slice(offset, len).ToArray());
        }
        return chunks;
    }

    public static LiveServerEvent? ParseEvent(string json)
    {
        var node = J.Parse(json);
        if (node == null) return null;
        var type = node.Str("type") ?? "";
        switch (type)
        {
            case "session.created" or "session.updated":
                return new LiveServerEvent.SessionReady();
            case "input_audio_buffer.speech_started":
                return new LiveServerEvent.SpeechStarted();
            case "input_audio_buffer.speech_stopped":
                return new LiveServerEvent.SpeechStopped();
            case "conversation.item.input_audio_transcription.delta":
                return new LiveServerEvent.UserTranscriptDelta(node.Str("delta") ?? "");
            case "conversation.item.input_audio_transcription.completed":
                return new LiveServerEvent.UserTranscriptFinal((node.Str("transcript") ?? "").Trim());
            case "response.audio.delta" or "response.output_audio.delta":
                if (node.Str("delta") is { Length: > 0 } b64)
                {
                    try { return new LiveServerEvent.AssistantAudioDelta(Convert.FromBase64String(b64)); }
                    catch (FormatException) { return null; }
                }
                return null;
            case "response.audio_transcript.delta" or "response.output_audio_transcript.delta" or "response.text.delta":
                return new LiveServerEvent.AssistantTextDelta(node.Str("delta") ?? "");
            case "response.audio_transcript.done" or "response.output_audio_transcript.done":
                return new LiveServerEvent.AssistantDone(node.Str("transcript"));
            case "response.done":
                return new LiveServerEvent.AssistantDone(null);
            case "response.function_call_arguments.done":
                return new LiveServerEvent.FunctionCall(
                    node.Str("call_id") ?? "",
                    node.Str("name") ?? "",
                    node.Str("arguments") ?? "{}");
            case "error":
                var errObj = node.Obj("error");
                var msg = errObj?.Str("message") ?? node.Str("message") ?? "Live voice error.";
                var errType = errObj?.Str("type") ?? "";
                var fatal = errType is "invalid_request_error" or "authentication_error" or "server_error";
                return new LiveServerEvent.Error(VoiceReport.Scrub(msg), fatal);
            default:
                return null;
        }
    }
}

// MARK: - Grok Live (GrokLiveWire.swift)

public sealed record GrokLiveStatus(
    bool Available,
    bool Configured,
    string? DefaultVoice = null,
    string? Reason = null)
{
    public static readonly GrokLiveStatus Unavailable = new(false, false);

    public static GrokLiveStatus Parse(JsonNode? node)
    {
        if (node == null) return Unavailable;
        var available = node.Bool("available") ?? node.Bool("enabled") ?? false;
        var configured = node.Bool("configured") ?? available;
        return new GrokLiveStatus(available, configured, node.Text("voice") ?? node.Text("default_voice"),
            node.Text("reason") ?? node.Text("detail"));
    }
}

public sealed record GrokLiveSession(
    string ClientSecret,
    Uri WebSocketUrl,
    string Voice,
    string? Model = null,
    DateTimeOffset? ExpiresAt = null)
{
    public static readonly Uri DefaultEndpoint = new("wss://api.x.ai/v1/realtime");

    public static GrokLiveSession? Parse(JsonNode? node)
    {
        if (node == null) return null;
        var secret = node.Text("client_secret")
            ?? node.Get("client_secret")?.Text("value")
            ?? node.Text("token");
        if (string.IsNullOrWhiteSpace(secret)) return null;
        var url = DefaultEndpoint;
        if ((node.Text("ws_url") ?? node.Text("url")) is { } raw && Uri.TryCreate(raw, UriKind.Absolute, out var parsed))
            url = parsed;
        var voice = node.Text("voice") ?? LiveVoices.DefaultGrokVoice;
        var expiresAt = node.UnixTime("expires_at") ?? node.Get("client_secret")?.UnixTime("expires_at");
        return new GrokLiveSession(secret, url, voice, node.Text("model"), expiresAt);
    }
}

public enum GrokAction { None, AskAgent, StopConversation }

public enum GrokLiveStage { Connecting, Ready, Listening, Thinking, Delegating, Speaking, Reconnecting, Closed }

public static class GrokLiveCalls
{
    public static (GrokAction Action, string Prompt) ParseCall(string name, string argumentsJson)
    {
        var clean = name.Trim().ToLowerInvariant();
        if (clean is LiveVoiceWire.EndVoiceToolName or "stop_conversation" or "hang_up")
            return (GrokAction.StopConversation, "");
        if (clean is LiveVoiceWire.AskAgentToolName or "delegate" or "run_agent")
        {
            var args = J.Parse(argumentsJson);
            var prompt = args?.Text("request") ?? args?.Text("prompt") ?? args?.Text("query") ?? "";
            return (GrokAction.AskAgent, prompt);
        }
        return (GrokAction.None, "");
    }
}

public static class GrokLiveWire
{
    public static string SessionUpdate(string voice, string instructions) =>
        LiveVoiceWire.SessionUpdate(string.IsNullOrWhiteSpace(voice) ? LiveVoices.DefaultGrokVoice : voice, instructions, offerTools: true);

    public static string AudioAppend(ReadOnlySpan<byte> pcm24kBytes) => LiveVoiceWire.AudioAppend(pcm24kBytes);
    public static string AudioCommit() => LiveVoiceWire.AudioCommit();
    public static string ToolResult(string callId, string output) => LiveVoiceWire.FunctionCallOutput(callId, output);
    public static LiveServerEvent? ParseEvent(string json) => LiveVoiceWire.ParseEvent(json);
}
