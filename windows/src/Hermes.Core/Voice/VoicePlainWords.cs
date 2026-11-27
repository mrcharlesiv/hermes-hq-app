using System.Text;
using System.Text.Json.Nodes;
using Hermes.Core.Gateways;
using Hermes.Core.Net;

namespace Hermes.Core.Voice;

// Port of HermesKit/Voice/VoicePlainWords.swift: plain-English failure classification and wording
// for Dictation and Talk (no raw stack traces, HTTP bodies, or protocol errors in the headline).

public enum VoiceFailureKind
{
    MicDenied,
    MicBusy,
    MicFailed,
    Offline,
    Timeout,
    ServerError,
    BadAudio,
    SttOff,
    TtsOff,
    LiveOff,
    SessionEnded,
    Cancelled,
    Unknown,
}

public sealed record VoiceFailure(
    VoiceFailureKind Kind,
    string Title,
    string Message,
    string? Detail = null,
    bool Retryable = true);

public static class VoicePlainWords
{
    public static string Title(VoiceFailureKind kind) => kind switch
    {
        VoiceFailureKind.MicDenied => "Microphone Access Is Off",
        VoiceFailureKind.MicBusy => "Microphone Is Busy",
        VoiceFailureKind.MicFailed => "Couldn’t Use the Microphone",
        VoiceFailureKind.Offline => "Can’t Reach Hermes",
        VoiceFailureKind.Timeout => "Hermes Didn’t Answer in Time",
        VoiceFailureKind.SttOff => "Speech-to-Text Is Off",
        VoiceFailureKind.TtsOff => "Voice Replies Are Off",
        VoiceFailureKind.LiveOff => "Live Voice Isn’t Available",
        VoiceFailureKind.SessionEnded => "Sign In Again",
        VoiceFailureKind.BadAudio => "Audio Couldn’t Be Played",
        _ => "Voice Problem",
    };

    public static bool IsOffline(Exception error) =>
        error is GatewayException g && (g.Code == "offline" || g.IsNotConnected || g.IsConnectionLost);

    public static bool IsAuth(Exception error) =>
        error is GatewayException g && (g.Code == "session-ended" || g.Status is 401 or 403);

    public static string? GatewayErrorDetail(GatewayException g)
    {
        if (!string.IsNullOrWhiteSpace(g.Body))
        {
            var json = J.Parse(g.Body);
            var detail = json?.Str("detail") ?? json?.Str("error") ?? json?.Str("message");
            if (!string.IsNullOrWhiteSpace(detail)) return VoiceReport.Scrub(detail);
        }
        return string.IsNullOrWhiteSpace(g.Message) ? null : VoiceReport.Scrub(g.Message);
    }

    public static VoiceFailure Plain(Exception error, string action)
    {
        if (error is OperationCanceledException)
            return new VoiceFailure(VoiceFailureKind.Cancelled, "Stopped", "Cancelled.", Retryable: false);

        if (error is GatewayException g)
        {
            var detail = GatewayErrorDetail(g);
            if (g.Code == "session-ended" || g.Status == 401)
                return new VoiceFailure(VoiceFailureKind.SessionEnded, Title(VoiceFailureKind.SessionEnded),
                    "Your session on this gateway ended. Sign in again.", detail, Retryable: false);
            if (g.Code == "timeout" || g.Status is 408 or 504 or 524)
                return new VoiceFailure(VoiceFailureKind.Timeout, Title(VoiceFailureKind.Timeout),
                    $"Timed out trying to {action}. {HostWord.Sentence} may be busy, asleep, or off.", detail);
            if (g.Code == "offline" || g.IsNotConnected || g.IsConnectionLost)
                return new VoiceFailure(VoiceFailureKind.Offline, Title(VoiceFailureKind.Offline),
                    $"Can’t reach {HostWord.Phrase} to {action}. Check your connection and try again.", detail);
            if (g.Status == 429)
                return new VoiceFailure(VoiceFailureKind.ServerError, Title(VoiceFailureKind.ServerError),
                    "Your gateway is busy right now. Wait a moment, then try again.", detail);
            if (g.Status is 404 or 405 or 501)
                return new VoiceFailure(VoiceFailureKind.LiveOff, Title(VoiceFailureKind.LiveOff),
                    $"{HostWord.Sentence} doesn’t support that voice feature yet. Updating Hermes may help.", detail, Retryable: false);
            if (g.Status >= 500)
                return new VoiceFailure(VoiceFailureKind.ServerError, Title(VoiceFailureKind.ServerError),
                    $"Couldn’t {action}. {MemoUploader.PlainWords(g.Status)}", detail);
            var msg = !string.IsNullOrWhiteSpace(detail)
                ? $"Couldn’t {action}: {detail}"
                : $"Couldn’t {action}. Try again.";
            return new VoiceFailure(VoiceFailureKind.ServerError, Title(VoiceFailureKind.ServerError), msg, detail);
        }

        var code = error.HResult;
        if (code is 561_017_449 or 560_557_684 or 561_145_187 or unchecked((int)0x8889000A))
            return new VoiceFailure(VoiceFailureKind.MicBusy, Title(VoiceFailureKind.MicBusy),
                "A call or another app is using the microphone.", VoiceReport.Scrub(error.Message));

        var scrubbed = VoiceReport.Scrub(error.Message);
        return new VoiceFailure(VoiceFailureKind.Unknown, Title(VoiceFailureKind.Unknown),
            string.IsNullOrEmpty(scrubbed) ? $"Couldn’t {action}. Try again." : $"Couldn’t {action}: {scrubbed}",
            string.IsNullOrEmpty(scrubbed) ? null : scrubbed);
    }

    public static string FormatBytesDetail(byte[]? data) =>
        data is { Length: > 0 } ? VoiceReport.Scrub(Encoding.UTF8.GetString(data, 0, Math.Min(data.Length, 512))) : "";
}
