using System.Text.Json.Nodes;
using Hermes.Core.Questions;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Voice;

// Port of HermesKit/Voice/TalkTypes.swift, LiveVoices.swift, VoiceQuestion.swift, VoiceChatRecord.swift.

public enum TalkStatus
{
    Idle,
    Starting,
    Listening,
    Transcribing,
    Thinking,
    Waiting,
    Speaking,
    Muted,
    Paused,
    Stopped,
}

public enum TalkPauseCause
{
    Silence,
    Interrupted,
    RouteLost,
    OtherAudio,
    Background,
    Question,
    Approval,
    User,
    LostSpeech,
    Disconnected,
}

public enum TalkNoticeKind
{
    MicDenied,
    MicFailed,
    SttOff,
    TtsOff,
    Offline,
    TranscribeFailed,
    SpeechFailed,
    LiveFailed,
    LiveFallback,
    MeterLost,
    SilencePaused,
    Interrupted,
    RouteLost,
    SessionEnded,
    Busy,
    Generic,
}

public enum TalkNoticeAction
{
    None,
    OpenSettings,
    Retry,
    Resume,
    VoiceSettings,
    SwitchToClassic,
    Dismiss,
}

public sealed record TalkNotice(
    TalkNoticeKind Kind,
    string Title,
    string Message,
    string? Detail = null,
    TalkNoticeAction Action = TalkNoticeAction.None,
    bool Fatal = false)
{
    public string? ActionTitle => Action switch
    {
        TalkNoticeAction.OpenSettings => PrivacySettingsWords.OpenTitle,
        TalkNoticeAction.Retry => "Try Again",
        TalkNoticeAction.Resume => "Resume",
        TalkNoticeAction.VoiceSettings => "Voice Settings…",
        TalkNoticeAction.SwitchToClassic => "Use Standard Voice",
        _ => null,
    };

    public bool Copies => Detail != null || Action != TalkNoticeAction.OpenSettings;

    public static TalkNotice MicDenied() => new(
        TalkNoticeKind.MicDenied,
        "Microphone Access Is Off",
        $"Turn on Microphone for {MemoNotice.AppName} in {PrivacySettingsWords.Place} to start a voice conversation.",
        Action: TalkNoticeAction.OpenSettings,
        Fatal: true);

    public static TalkNotice SilencePaused() => new(
        TalkNoticeKind.SilencePaused,
        "Voice Chat Paused",
        "Paused after a couple minutes of silence. Click Resume when you’re ready.",
        Action: TalkNoticeAction.Resume);

    public static TalkNotice Interrupted(string? detail = null) => new(
        TalkNoticeKind.Interrupted,
        "Voice Chat Paused",
        "Another call or app took the microphone.",
        detail,
        TalkNoticeAction.Resume);

    public static TalkNotice RouteLost() => new(
        TalkNoticeKind.RouteLost,
        "Audio Device Disconnected",
        "Your headset or microphone disconnected.",
        Action: TalkNoticeAction.Resume);

    public static TalkNotice SttOff() => new(
        TalkNoticeKind.SttOff,
        "Speech-to-Text Is Off",
        "Turn on Speech-to-Text in Voice Settings to talk out loud.",
        Action: TalkNoticeAction.VoiceSettings,
        Fatal: true);

    public static TalkNotice LiveFallback(string? detail = null) => new(
        TalkNoticeKind.LiveFallback,
        "Switched to Standard Voice",
        "Live voice disconnected, so this conversation continued with standard voice.",
        detail,
        TalkNoticeAction.None);

    public static TalkNotice FromFailure(VoiceFailure failure, bool fatal = false)
    {
        var action = failure.Kind switch
        {
            VoiceFailureKind.MicDenied => TalkNoticeAction.OpenSettings,
            VoiceFailureKind.SttOff or VoiceFailureKind.TtsOff => TalkNoticeAction.VoiceSettings,
            _ when failure.Retryable => TalkNoticeAction.Retry,
            _ => TalkNoticeAction.None,
        };
        var kind = failure.Kind switch
        {
            VoiceFailureKind.MicDenied => TalkNoticeKind.MicDenied,
            VoiceFailureKind.MicBusy or VoiceFailureKind.MicFailed => TalkNoticeKind.MicFailed,
            VoiceFailureKind.Offline or VoiceFailureKind.Timeout => TalkNoticeKind.Offline,
            VoiceFailureKind.SttOff => TalkNoticeKind.SttOff,
            VoiceFailureKind.TtsOff => TalkNoticeKind.TtsOff,
            VoiceFailureKind.SessionEnded => TalkNoticeKind.SessionEnded,
            _ => TalkNoticeKind.Generic,
        };
        return new TalkNotice(kind, failure.Title, failure.Message, failure.Detail, action, fatal);
    }
}

public enum TalkEnd
{
    User,
    SpokenStop,
    TypedStop,
    ChatLeft,
    Error,
    SignedOut,
    AccountSwitch,
    Replaced,
}

public enum TalkEngine
{
    Classic,
    GptLive,
    GrokLive,
}

public static class TalkEngineInfo
{
    public static string Label(this TalkEngine engine) => engine switch
    {
        TalkEngine.GptLive => "GPT Live",
        TalkEngine.GrokLive => "Grok Live",
        _ => "Standard Voice",
    };

    public static string Key(this TalkEngine engine) => engine switch
    {
        TalkEngine.GptLive => "gpt-live",
        TalkEngine.GrokLive => "grok-live",
        _ => "classic",
    };

    public static TalkEngine Parse(string? raw) => raw?.Trim().ToLowerInvariant() switch
    {
        "gpt-live" or "gpt_live" or "openai-live" or "live" => TalkEngine.GptLive,
        "grok-live" or "grok_live" or "xai-live" => TalkEngine.GrokLive,
        _ => TalkEngine.Classic,
    };

    public static bool IsLive(this TalkEngine engine) => engine is TalkEngine.GptLive or TalkEngine.GrokLive;
}

public sealed record TalkConfig(
    bool SttEnabled,
    bool TtsEnabled,
    bool LiveOffered,
    bool GrokOffered,
    string? VoiceName = null,
    string? Provider = null,
    bool AutoSpeak = true,
    string? Language = null)
{
    public static readonly TalkConfig Default = new(true, true, false, false);

    public static TalkConfig Parse(JsonNode? config)
    {
        if (config == null) return Default;
        var stt = config.Get("stt");
        var tts = config.Get("tts");
        var voice = config.Get("voice");
        var sttOn = stt.Bool("enabled") != false;
        var ttsOn = tts.Bool("enabled") != false;
        var liveOn = voice.Bool("live_enabled") == true
            || config.Get("live_voice").Bool("enabled") == true
            || config.Get("realtime").Bool("enabled") == true;
        var grokOn = voice.Bool("grok_live_enabled") == true
            || config.Get("grok_live").Bool("enabled") == true;
        var voiceName = tts.Text("voice") ?? voice.Text("voice");
        var provider = tts.Text("provider") ?? voice.Text("provider");
        var language = stt.Text("language") ?? voice.Text("language");
        var autoSpeak = voice.Bool("auto_speak") != false;
        return new TalkConfig(sttOn, ttsOn, liveOn, grokOn, voiceName, provider, autoSpeak, language);
    }
}

public static class TalkClock
{
    public static string Elapsed(double seconds) => MemoPolicy.Length(seconds);
    public static string Total(double seconds) => MemoPolicy.Total(seconds);
}

public enum TalkRouteKind { Default, Speaker, Headphones, Bluetooth, Usb }

public sealed record TalkAudioRoute(
    string Id,
    string Name,
    TalkRouteKind Kind,
    bool IsActive,
    bool IsDefault = false);

public sealed record TalkRouteChoice(string Id, string Label, TalkRouteKind Kind, bool IsSelected);

public sealed record TalkSpeakerButton(bool Enabled, bool Active, string Label, string Glyph);

// MARK: - Talk preferences & tips

public static class TalkPrefs
{
    public const string IntroSeenKey = "hq.voice.introSeen";
    public const string EngineKey = "hq.voice.engine";
    public const string LiveVoiceKey = "hq.voice.liveVoice";
    public const string GrokVoiceKey = "hq.voice.grokVoice";
    public const string SpeakRepliesKey = "hq.voice.talkSpeakReplies";

    public static bool IntroSeen(IPreferences prefs) => prefs.Get(IntroSeenKey) == "true";
    public static void MarkIntroSeen(IPreferences prefs) => prefs.Set(IntroSeenKey, "true");

    public static TalkEngine Engine(IPreferences prefs) => TalkEngineInfo.Parse(prefs.Get(EngineKey));
    public static void SetEngine(IPreferences prefs, TalkEngine engine) => prefs.Set(EngineKey, engine.Key());

    public static bool SpeakReplies(IPreferences prefs) => prefs.Get(SpeakRepliesKey) != "false";
    public static void SetSpeakReplies(IPreferences prefs, bool on) => prefs.Set(SpeakRepliesKey, on ? "true" : "false");

    public static string LiveVoice(IPreferences prefs, TalkEngine engine) => engine switch
    {
        TalkEngine.GrokLive => prefs.Get(GrokVoiceKey) is { Length: > 0 } g ? g : LiveVoices.DefaultGrokVoice,
        _ => prefs.Get(LiveVoiceKey) is { Length: > 0 } v ? v : LiveVoices.DefaultGptVoice,
    };

    public static void SetLiveVoice(IPreferences prefs, TalkEngine engine, string voiceId)
    {
        if (engine == TalkEngine.GrokLive) prefs.Set(GrokVoiceKey, voiceId);
        else prefs.Set(LiveVoiceKey, voiceId);
    }
}

// MARK: - LiveVoices catalog (LiveVoices.swift)

public sealed record LiveVoice(string Id, string Name, string Description, TalkEngine Engine);

public static class LiveVoices
{
    public const string DefaultGptVoice = "alloy";
    public const string DefaultGrokVoice = "Ara";

    public static readonly IReadOnlyList<LiveVoice> Gpt =
    [
        new("alloy", "Alloy", "Balanced and clear", TalkEngine.GptLive),
        new("ash", "Ash", "Warm and steady", TalkEngine.GptLive),
        new("ballad", "Ballad", "Expressive and smooth", TalkEngine.GptLive),
        new("coral", "Coral", "Friendly and crisp", TalkEngine.GptLive),
        new("echo", "Echo", "Calm and resonant", TalkEngine.GptLive),
        new("sage", "Sage", "Composed and direct", TalkEngine.GptLive),
        new("shimmer", "Shimmer", "Bright and light", TalkEngine.GptLive),
        new("verse", "Verse", "Natural and upbeat", TalkEngine.GptLive),
    ];

    public static readonly IReadOnlyList<LiveVoice> Grok =
    [
        new("Ara", "Ara", "Warm and conversational", TalkEngine.GrokLive),
        new("Rex", "Rex", "Confident and clear", TalkEngine.GrokLive),
        new("Sal", "Sal", "Smooth and balanced", TalkEngine.GrokLive),
        new("Eve", "Eve", "Energetic and bright", TalkEngine.GrokLive),
        new("Leo", "Leo", "Steady and authoritative", TalkEngine.GrokLive),
    ];

    public static IReadOnlyList<LiveVoice> For(TalkEngine engine) => engine switch
    {
        TalkEngine.GrokLive => Grok,
        TalkEngine.GptLive => Gpt,
        _ => [],
    };

    public static LiveVoice? Find(TalkEngine engine, string? id) =>
        string.IsNullOrWhiteSpace(id) ? null
            : For(engine).FirstOrDefault(v => string.Equals(v.Id, id, StringComparison.OrdinalIgnoreCase));
}

// MARK: - VoiceQuestion (VoiceQuestion.swift)

public sealed record VoiceQuestion(string Id, string Prompt, IReadOnlyList<string> Choices, bool MultiSelect)
{
    public static VoiceQuestion From(ClarifyQuestion q) =>
        new(q.Qid, q.Question, q.Choices ?? [], q.MultiSelect);
}

public static class VoiceQuestionText
{
    /// Turns an agent's ClarifyQuestion into natural spoken wording.
    public static string Speakable(VoiceQuestion q)
    {
        var prompt = SpeechText.SanitizeForSpeech(q.Prompt);
        if (q.Choices.Count == 0) return prompt;
        var list = q.Choices.Count switch
        {
            1 => q.Choices[0],
            2 => $"{q.Choices[0]}, or {q.Choices[1]}",
            _ => string.Join(", ", q.Choices.Take(q.Choices.Count - 1)) + $", or {q.Choices[^1]}",
        };
        return string.IsNullOrEmpty(prompt) ? $"Your options are {list}." : $"{prompt} Your options are {list}.";
    }

    /// Matches a spoken answer ("option two", "the first one", or direct choice text) back to one of the choices.
    public static string? MatchChoice(string spoken, IReadOnlyList<string> choices)
    {
        if (string.IsNullOrWhiteSpace(spoken) || choices.Count == 0) return null;
        var norm = spoken.Trim().ToLowerInvariant();
        foreach (var choice in choices)
            if (string.Equals(choice.Trim(), norm, StringComparison.OrdinalIgnoreCase))
                return choice;
        foreach (var choice in choices)
            if (norm.Contains(choice.Trim().ToLowerInvariant(), StringComparison.Ordinal))
                return choice;

        string[] ordinals = ["first", "second", "third", "fourth", "fifth", "sixth"];
        for (var i = 0; i < Math.Min(ordinals.Length, choices.Count); i++)
        {
            var num = (i + 1).ToString();
            if (norm.Contains(ordinals[i], StringComparison.Ordinal)
                || norm == num
                || norm.Contains($"option {num}", StringComparison.Ordinal)
                || norm.Contains($"number {num}", StringComparison.Ordinal))
                return choices[i];
        }
        return null;
    }
}

// MARK: - VoiceChatRecord (VoiceChatRecord.swift)

public sealed record VoiceChatRecord(
    string ChatScope,
    string BotName,
    TalkEngine Engine,
    DateTimeOffset StartedAt,
    DateTimeOffset EndedAt,
    double DurationSeconds,
    int Turns,
    TalkEnd EndReason,
    string? Summary = null)
{
    public static string EndedCaption(double durationSeconds) =>
        durationSeconds >= 1 ? $"Voice chat ended · {TalkClock.Total(durationSeconds)}" : "Voice chat ended";

    public string Caption => EndedCaption(DurationSeconds);
}
