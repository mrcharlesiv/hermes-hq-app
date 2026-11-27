using System.Text;
using System.Text.Json.Nodes;
using Hermes.Core.Chat;
using Hermes.Core.Net;
using Hermes.Core.Questions;
using Hermes.Core.Transcripts;
using Hermes.Core.Voice;

namespace Hermes.Core.Tests.Voice;

public sealed class TalkTests
{
    private sealed class MemPrefs : IPreferences
    {
        private readonly Dictionary<string, string> _map = [];
        public string? Get(string key) => _map.TryGetValue(key, out var v) ? v : null;
        public void Set(string key, string? value)
        {
            if (value == null) _map.Remove(key);
            else _map[key] = value;
        }
    }

    private sealed class FakeTalkCapture : ITalkCapturing
    {
        public bool IsCapturing { get; private set; }
        public bool IsMuted { get; set; }
        public bool BargeInEnabled { get; set; }
        public int SampleRate => 16000;
        public TalkTake? NextFlush { get; set; }

        public event Action<double>? LevelChanged;
        public event Action? SpeechStarted;
        public event Action<TalkTake>? TakeCompleted;
        public event Action? BargeInDetected;
        public event Action<short[]>? PcmCaptured;
        public event Action<TalkCaptureError, string>? Failed;

        public Task StartAsync(CancellationToken ct = default)
        {
            IsCapturing = true;
            return Task.CompletedTask;
        }

        public TalkTake? FlushNow() => NextFlush;
        public void Stop() => IsCapturing = false;
        public void Dispose() => Stop();

        public void EmitLevel(double l) => LevelChanged?.Invoke(l);
        public void EmitSpeechStarted() => SpeechStarted?.Invoke();
        public void EmitTake(TalkTake take) => TakeCompleted?.Invoke(take);
        public void EmitBargeIn() => BargeInDetected?.Invoke();
        public void EmitPcm(short[] pcm) => PcmCaptured?.Invoke(pcm);
        public void EmitFailed(TalkCaptureError err, string msg) => Failed?.Invoke(err, msg);
    }

    private sealed class FakeTalkSpeaker : ITalkSpeaker
    {
        public bool IsSpeaking { get; private set; }
        public List<string> Spoken { get; } = [];
        public List<byte[]> PcmChunks { get; } = [];
        public int StopCount { get; private set; }
        public int FlushCount { get; private set; }
        public TalkSpeechOutcome Outcome { get; set; } = TalkSpeechOutcome.Completed;

        public event Action<double>? LevelChanged;

        public Task<TalkSpeechOutcome> SpeakAsync(string text, Func<string, CancellationToken, Task<SpeechClip>>? gatewaySpeak,
            CancellationToken ct = default)
        {
            IsSpeaking = true;
            Spoken.Add(text);
            LevelChanged?.Invoke(0.7);
            IsSpeaking = false;
            return Task.FromResult(Outcome);
        }

        public void PlayPcmChunk(ReadOnlySpan<byte> pcm24k) => PcmChunks.Add(pcm24k.ToArray());
        public void FlushPcm() => FlushCount++;
        public void Stop() { IsSpeaking = false; StopCount++; }
        public void Dispose() { }
    }

    private sealed class FakeTalkBridge : ITalkChatBridge
    {
        public string Scope { get; set; } = "acct|ivy|chat-1";
        public string Profile { get; set; } = "ivy";
        public string BotName { get; set; } = "Ivy";
        public bool IsBusy { get; set; }
        public List<string> SentTurns { get; } = [];
        public int StopCalls { get; private set; }
        public SpokenReply? Reply { get; set; }

        public event Action? Changed;

        public SpokenReply? NewestReply() => Reply;
        public IReadOnlyList<(string Role, string Text)> RecentHistory(int maxMessages = 10) => [("user", "Hello"), ("assistant", "Hi there")];

        public Task<SendOutcome> SendTurnAsync(string text, CancellationToken ct = default)
        {
            SentTurns.Add(text);
            IsBusy = true;
            return Task.FromResult(SendOutcome.Accepted);
        }

        public void CompleteReply(string id, string text)
        {
            Reply = new SpokenReply(id, text, Pending: false);
            IsBusy = false;
            Changed?.Invoke();
        }

        public Task StopTurnAsync() { StopCalls++; IsBusy = false; return Task.CompletedTask; }
    }

    private sealed class FakeVoiceGateway : IVoiceGateway
    {
        public TalkConfig Config { get; set; } = new(true, true, LiveOffered: true, GrokOffered: true);
        public string NextTranscript { get; set; } = "Check the status";

        public Task<TalkConfig> ConfigAsync(string? profile, CancellationToken ct = default) => Task.FromResult(Config);
        public Task<string> TranscribeAsync(byte[] audio, string mime, string? profile, CancellationToken ct = default) => Task.FromResult(NextTranscript);
        public Task<SpeechClip> SpeakAsync(string text, string? voice, string? profile, CancellationToken ct = default) =>
            Task.FromResult(new SpeechClip(TalkWave.EncodeWav([100, -100]), "audio/wav", text));
        public Task<LiveVoiceStatus> LiveStatusAsync(string? profile, CancellationToken ct = default) =>
            Task.FromResult(new LiveVoiceStatus(true, true, "alloy", "gpt-4o-realtime"));
        public Task<VoiceLease> LiveSessionAsync(string? profile, string? voice, CancellationToken ct = default) =>
            Task.FromResult(new VoiceLease("ephemeral-token", new Uri("wss://example.invalid/realtime"), "gpt-4o-realtime", voice ?? "alloy", null));
        public Task<GrokLiveStatus> GrokStatusAsync(string? profile, CancellationToken ct = default) =>
            Task.FromResult(new GrokLiveStatus(true, true, "Ara"));
        public Task<GrokLiveSession> GrokSessionAsync(string? profile, string? voice, CancellationToken ct = default) =>
            Task.FromResult(new GrokLiveSession("grok-secret", GrokLiveSession.DefaultEndpoint, voice ?? "Ara"));
    }

    private sealed class FakeLiveTransport : ILiveVoiceTransport
    {
        public List<string> Controls { get; } = [];
        public List<byte[]> AudioSent { get; } = [];
        public bool Connected { get; private set; }
        public event Action<LiveServerEvent>? EventReceived;

        public Task ConnectAsync(TalkEngine engine, VoiceLease? gptLease, GrokLiveSession? grokSession, string instructions,
            CancellationToken ct = default)
        {
            Connected = true;
            return Task.CompletedTask;
        }

        public Task SendAudioAsync(ReadOnlyMemory<byte> pcm24k, CancellationToken ct = default)
        {
            AudioSent.Add(pcm24k.ToArray());
            return Task.CompletedTask;
        }

        public Task SendControlAsync(string json, CancellationToken ct = default)
        {
            Controls.Add(json);
            return Task.CompletedTask;
        }

        public Task CloseAsync(CancellationToken ct = default) { Connected = false; return Task.CompletedTask; }
        public ValueTask DisposeAsync() { Connected = false; return ValueTask.CompletedTask; }

        public void Emit(LiveServerEvent ev) => EventReceived?.Invoke(ev);
    }

    [Fact]
    public void ClassicTalkLoopReducerCoversLifecycleBargeInMuteSilenceAndFailureLimits()
    {
        var (s1, fx1) = TalkLoop.Reduce(TalkLoopState.Initial, new TalkLoopInput.Start());
        Assert.Equal(TalkStatus.Starting, s1.Status);
        Assert.Contains(fx1, e => e is TalkLoopEffect.StartCapture);

        var (s2, fx2) = TalkLoop.Reduce(s1, new TalkLoopInput.Started());
        Assert.Equal(TalkStatus.Listening, s2.Status);
        Assert.Contains(fx2, e => e is TalkLoopEffect.PlayChime);

        var (s3, _) = TalkLoop.Reduce(s2, new TalkLoopInput.SpeechDetected());
        Assert.True(s3.HeardSpeech);

        var (s4, fx4) = TalkLoop.Reduce(s3, new TalkLoopInput.TakeReady([1, 2, 3], LiveWords: "Hello there"));
        Assert.Equal(TalkStatus.Thinking, s4.Status);
        Assert.Equal(1, s4.Turns);
        Assert.Contains(fx4, e => e is TalkLoopEffect.SubmitTurn { Text: "Hello there" });

        var (s5, fx5) = TalkLoop.Reduce(s4, new TalkLoopInput.ReplyReady("All tests **passed**!"));
        Assert.Equal(TalkStatus.Speaking, s5.Status);
        Assert.Contains(fx5, e => e is TalkLoopEffect.Speak { Text: "All tests passed!" });

        // Barge-in interrupts speech immediately
        var (s6, fx6) = TalkLoop.Reduce(s5, new TalkLoopInput.BargeIn());
        Assert.Equal(TalkStatus.Listening, s6.Status);
        Assert.True(s6.HeardSpeech);
        Assert.Contains(fx6, e => e is TalkLoopEffect.StopSpeech);
        Assert.Contains(fx6, e => e is TalkLoopEffect.StartCapture);

        // Mute / Unmute
        var (sMuted, fxMuted) = TalkLoop.Reduce(s6, new TalkLoopInput.MuteToggle());
        Assert.Equal(TalkStatus.Muted, sMuted.Status);
        Assert.Contains(fxMuted, e => e is TalkLoopEffect.StopCapture);
        var (sUnmuted, _) = TalkLoop.Reduce(sMuted, new TalkLoopInput.MuteToggle());
        Assert.Equal(TalkStatus.Listening, sUnmuted.Status);

        // Silence hint & pause
        var (sHint, _) = TalkLoop.Reduce(sUnmuted, new TalkLoopInput.SilenceHint());
        Assert.True(sHint.SilenceHint);
        var (sPaused, _) = TalkLoop.Reduce(sHint, new TalkLoopInput.SilencePause());
        Assert.Equal(TalkStatus.Paused, sPaused.Status);
        Assert.Equal(TalkNoticeKind.SilencePaused, sPaused.Notice?.Kind);

        // 3 consecutive transcribe failures stop the session fatally
        var sFail = sUnmuted;
        for (var i = 0; i < TalkLoop.MaxConsecutiveTranscribeFailures; i++)
        {
            (sFail, _) = TalkLoop.Reduce(sFail, new TalkLoopInput.TakeReady([1, 2]));
            (sFail, _) = TalkLoop.Reduce(sFail, new TalkLoopInput.TranscribeFailed(new TalkNotice(TalkNoticeKind.TranscribeFailed, "Fail", "oops")));
        }
        Assert.Equal(TalkStatus.Stopped, sFail.Status);
        Assert.True(sFail.Notice?.Fatal);
    }

    [Fact]
    public void LiveTalkLoopReducerHandlesReconnectDelegationAndFallbackToClassic()
    {
        var (s1, fx1) = LiveTalkLoop.Reduce(LiveTalkState.Initial, new LiveTalkInput.Connect());
        Assert.Equal(TalkStatus.Starting, s1.Status);
        Assert.Contains(fx1, e => e is LiveTalkEffect.OpenTransport);

        var (s2, fx2) = LiveTalkLoop.Reduce(s1, new LiveTalkInput.Connected());
        Assert.Equal(TalkStatus.Listening, s2.Status);
        Assert.Contains(fx2, e => e is LiveTalkEffect.PlayChime);

        var (s3, fx3) = LiveTalkLoop.Reduce(s2, new LiveTalkInput.DelegateRequest("call-1", "check git status"));
        Assert.True(s3.IsDelegating);
        Assert.Equal(TalkStatus.Thinking, s3.Status);
        Assert.Contains(fx3, e => e is LiveTalkEffect.RunDelegation { CallId: "call-1", Prompt: "check git status" });

        var (s4, fx4) = LiveTalkLoop.Reduce(s3, new LiveTalkInput.DelegateFinished("call-1", "clean"));
        Assert.False(s4.IsDelegating);
        Assert.Contains(fx4, e => e is LiveTalkEffect.SendToolResult { CallId: "call-1", Result: "clean" });

        // Exhaust reconnects -> fallback to classic
        var sDisc = s4;
        IReadOnlyList<LiveTalkEffect> lastFx = [];
        for (var attempt = 0; attempt <= s4.MaxReconnects; attempt++)
            (sDisc, lastFx) = LiveTalkLoop.Reduce(sDisc, new LiveTalkInput.Disconnected("socket dropped"));
        Assert.Contains(lastFx, e => e is LiveTalkEffect.SwitchToClassic);
    }

    [Fact]
    public async Task TalkControllerClassicTurnEchoGuardStopPhrasesSilenceAndAwayPill()
    {
        var now = new DateTimeOffset(2026, 6, 1, 12, 0, 0, TimeSpan.Zero);
        var capture = new FakeTalkCapture();
        var speaker = new FakeTalkSpeaker();
        var bridge = new FakeTalkBridge();
        var gateway = new FakeVoiceGateway { NextTranscript = "What is the weather?" };
        var prefs = new MemPrefs();
        using var ctrl = new TalkController(capture, speaker, prefs, gateway, now: () => now);

        var chimes = 0;
        VoiceChatRecord? record = null;
        string? returnTarget = null;
        ctrl.ChimeRequested += () => chimes++;
        ctrl.RecordCompleted += r => record = r;
        ctrl.ReturnToChatRequested += s => returnTarget = s;

        await ctrl.StartAsync(bridge, TalkEngine.Classic);
        Assert.Equal(TalkStatus.Listening, ctrl.Status);
        Assert.Equal(1, chimes);

        // User speaks -> gateway transcribes -> chat sends -> reply spoken
        capture.EmitSpeechStarted();
        capture.EmitTake(new TalkTake(TalkWave.EncodeWav([500, -500]), 1.2));
        Assert.True(await VoiceFixtures.WaitUntil(() => bridge.SentTurns.Count == 1));
        Assert.Equal("What is the weather?", bridge.SentTurns[0]);

        bridge.CompleteReply("msg-1", "It is sunny and seventy degrees.");
        Assert.True(await VoiceFixtures.WaitUntil(() => speaker.Spoken.Count == 1));
        Assert.Equal(TalkStatus.Listening, ctrl.Status);

        // Echo guard ignores bot's own words heard 1 second later
        now = now.AddSeconds(1);
        gateway.NextTranscript = "sunny and seventy degrees";
        capture.EmitTake(new TalkTake(TalkWave.EncodeWav([200, -200]), 0.8));
        await Task.Delay(50);
        Assert.Single(bridge.SentTurns); // still 1 — echo was dropped

        // Navigating away shows the away pill and Return targets the active chat
        ctrl.ScreenChanged("acct|otto|other-chat");
        Assert.True(ctrl.CurrentState.AwayPill.Visible);
        Assert.Equal("Ivy", ctrl.CurrentState.AwayPill.BotName);
        ctrl.RequestReturnToChat();
        Assert.Equal(bridge.Scope, returnTarget);
        ctrl.ScreenChanged(bridge.Scope);
        Assert.False(ctrl.CurrentState.AwayPill.Visible);

        // Silence clock: 30s hint, 120s pause
        ctrl.Tick(31);
        Assert.True(ctrl.CurrentState.SilenceHint);
        ctrl.Tick(95);
        Assert.Equal(TalkStatus.Paused, ctrl.Status);
        await ctrl.ResumeAsync();
        Assert.Equal(TalkStatus.Listening, ctrl.Status);

        // Typed stop ends conversation cleanly and emits VoiceChatRecord
        Assert.True(ctrl.InterceptTypedSend(bridge.Scope, "stop"));
        Assert.Equal(TalkStatus.Idle, ctrl.Status);
        Assert.NotNull(record);
        Assert.Equal(TalkEnd.TypedStop, record!.EndReason);
        Assert.StartsWith("Voice chat ended", record.Caption);
    }

    [Fact]
    public async Task TalkControllerLiveModeDelegatesAskAgentAndEndsOnToolCall()
    {
        var capture = new FakeTalkCapture();
        var speaker = new FakeTalkSpeaker();
        var bridge = new FakeTalkBridge();
        var gateway = new FakeVoiceGateway();
        var prefs = new MemPrefs();
        FakeLiveTransport? activeTransport = null;

        using var ctrl = new TalkController(
            capture, speaker, prefs, gateway,
            liveFactory: () => activeTransport = new FakeLiveTransport());

        VoiceChatRecord? record = null;
        ctrl.RecordCompleted += r => record = r;

        await ctrl.StartAsync(bridge, TalkEngine.GrokLive);
        Assert.NotNull(activeTransport);
        activeTransport!.Emit(new LiveServerEvent.SessionReady());
        Assert.Equal(TalkStatus.Listening, ctrl.Status);

        // Audio delta streams to speaker PCM output
        activeTransport.Emit(new LiveServerEvent.AssistantAudioDelta([1, 2, 3, 4]));
        Assert.Equal(TalkStatus.Speaking, ctrl.Status);
        Assert.Single(speaker.PcmChunks);

        // ask_agent delegates to chat bridge and posts tool result back
        activeTransport.Emit(new LiveServerEvent.FunctionCall("call-99", "ask_agent", """{"request":"list open tasks"}"""));
        Assert.True(await VoiceFixtures.WaitUntil(() => bridge.SentTurns.Contains("list open tasks")));
        bridge.CompleteReply("msg-live-1", "Two tasks are open.");
        Assert.True(await VoiceFixtures.WaitUntil(() => activeTransport.Controls.Any(c => c.Contains("call-99"))));

        // end_voice_conversation tool call ends Talk
        activeTransport.Emit(new LiveServerEvent.FunctionCall("call-end", "end_voice_conversation", "{}"));
        Assert.Equal(TalkStatus.Idle, ctrl.Status);
        Assert.Equal(TalkEnd.SpokenStop, record?.EndReason);
    }

    [Fact]
    public void WireFramingStopWordsEchoQuestionsEventsScrubAndPlainWordsAreAccurate()
    {
        // Stop phrases
        Assert.True(TalkStopWord.IsStopPhrase("Stop talking, Ivy!", "Ivy"));
        Assert.True(TalkStopWord.IsStopPhrase("Goodbye."));
        Assert.False(TalkStopWord.IsStopPhrase("Don't stop yet please"));
        Assert.True(TalkStopWord.IsTypedStop("hang up"));

        // Echo similarity
        Assert.True(TalkEcho.IsEcho("sunny and seventy degrees", "It is sunny and seventy degrees outside.", 1.2));
        Assert.False(TalkEcho.IsEcho("check my calendar", "It is sunny and seventy degrees outside.", 1.2));
        Assert.False(TalkEcho.IsEcho("sunny and seventy degrees", "It is sunny and seventy degrees outside.", 10.0));

        // LiveVoiceWire / GrokLiveWire
        var update = LiveVoiceWire.SessionUpdate("coral", "Be concise.");
        Assert.Contains("\"voice\":\"coral\"", update);
        Assert.Contains("ask_agent", update);
        var chunks = LiveVoiceWire.ChunkPcm(new byte[10_000], 4800);
        Assert.Equal(3, chunks.Count);
        Assert.IsType<LiveServerEvent.FunctionCall>(LiveVoiceWire.ParseEvent(
            """{"type":"response.function_call_arguments.done","call_id":"c1","name":"ask_agent","arguments":"{\"request\":\"hi\"}"}"""));
        var (act, prompt) = GrokLiveCalls.ParseCall("ask_agent", """{"request":"status"}""");
        Assert.Equal(GrokAction.AskAgent, act);
        Assert.Equal("status", prompt);

        // VoiceWire helpers
        var dataUrl = "data:audio/wav;base64," + Convert.ToBase64String([1, 2, 3, 4]);
        var decoded = VoiceWire.DecodeDataUrl(dataUrl);
        Assert.NotNull(decoded);
        Assert.Equal("audio/wav", decoded!.Value.Mime);
        Assert.True(VoiceWire.IsPlayableMime("audio/mpeg; charset=utf-8"));
        var addr = GatewayAddress.Validated("https://gateway.example.test");
        var wsUri = VoiceWire.SocketUrl(addr, "/api/audio/live-stt", "tok123", "ivy");
        Assert.Equal("wss://gateway.example.test/api/audio/live-stt?profile=ivy&ticket=tok123", wsUri.ToString());

        // VoiceQuestionText
        var q = VoiceQuestion.From(new ClarifyQuestion("q1", "Which branch?", ["main", "release"], false));
        Assert.Contains("main, or release", VoiceQuestionText.Speakable(q));
        Assert.Equal("release", VoiceQuestionText.MatchChoice("pick the second one", q.Choices));

        // VoiceReport scrubbing redacts secrets and emails
        var scrubbed = VoiceReport.Scrub("Authorization: Bearer secretToken123 sk-1234567890abcdef test@example.com ?ticket=abc999");
        Assert.DoesNotContain("secretToken123", scrubbed);
        Assert.DoesNotContain("sk-1234567890abcdef", scrubbed);
        Assert.DoesNotContain("test@example.com", scrubbed);
        Assert.DoesNotContain("abc999", scrubbed);

        var events = new VoiceEvents(capacity: 3, nowSeconds: () => 1000);
        events.Record("line 1");
        events.Record("line 2");
        events.Record("line 3");
        events.Record("line 4");
        Assert.Equal(3, events.Snapshot().Count);
        Assert.True(VoiceReport.Holds(events.Text));

        // VoicePlainWords
        var timeoutFail = VoicePlainWords.Plain(new GatewayException("timeout", "timeout"), "transcribe");
        Assert.Equal(VoiceFailureKind.Timeout, timeoutFail.Kind);
        var authFail = VoicePlainWords.Plain(new GatewayException("session-ended", "expired", 401), "connect");
        Assert.Equal(VoiceFailureKind.SessionEnded, authFail.Kind);
        Assert.False(authFail.Retryable);
    }
}
