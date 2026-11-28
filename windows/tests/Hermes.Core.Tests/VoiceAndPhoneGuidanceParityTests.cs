using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json.Nodes;
using Hermes.Core.Attachments;
using Hermes.Core.Auth;
using Hermes.Core.Chat;
using Hermes.Core.Model;
using Hermes.Core.Net;
using Hermes.Core.PhoneCalls;
using Hermes.Core.Rpc;
using Hermes.Core.Tests.Voice;
using Hermes.Core.Transcripts;
using Hermes.Core.Voice;

namespace Hermes.Core.Tests;

/// Wave 3D parity tests covering:
/// 1. Voice Memos photo attachment during review (#521, 6e2cec67f)
/// 2. VoiceChatRecordCodec & TalkController live transcript card + dedup + NO_REPLY suppression
/// 3. Voice hardening (M17 memo live-words preservation across interruptions, M18 Talk stalled-output watchdog)
/// 4. samplehostClient Call Control Apps / Voice Profiles / Provision / Repair (H15) / Optimize / HasValidWebhookUrl / PhoneConnectionResolver / H6 404 & key redaction
/// 5. PhoneSetupCheck (H6 404 -> TeXML fail, H14 invalid/nil webhook fail, number status/connection mismatch, assistant call quality issues)
public sealed class VoiceAndPhoneGuidanceParityTests : IDisposable
{
    private const string FakesamplehostKey = "KEYTEST_SYNTHETIC_998877";
    private readonly VoiceTestStores _stores = new();

    public void Dispose() => _stores.Dispose();

    // =========================================================================
    // 1. Voice Memos Photo Attachment During Review (#521)
    // =========================================================================

    [Fact]
    public async Task SendMemoAsyncUploadsAndSubmitsPhotoAndFileAttachmentsInOneTurn()
    {
        await using var socket = new MiniLoopback();
        var account = new StoredAccount(socket.Url, "synthetic");
        await using var client = new HermesClient(new GatewaySession(GatewayAddress.Validated(socket.Url), account, new MemoryTokenStore()));
        var rest = new VoiceFakeClient(client.AccountId);
        _stores.Activate(client.AccountId);

        await using var chat = client.OpenChat("ivy", "20261128_120000_memo521", "Ivy");
        chat.MemoStores = _stores.Stores;
        chat.MemoGateway = rest;
        chat.MemoUploads = new MemoUploadState();

        await client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(15)).Token);
        await chat.EnsureRuntimeAsync();

        var memo = _stores.Recording(client.AccountId);
        var stagedPhoto = new DraftAttachment(
            Id: "att-photo-1",
            Kind: DraftKind.Image,
            Name: "whiteboard.jpg",
            LocalFile: Path.Combine(_stores.Base, "whiteboard.jpg"),
            ByteSize: 2048,
            PixelWidth: 1200,
            PixelHeight: 800,
            Upload: new UploadState.Uploaded("/Users/owner/.dispatch-attachments/u1/whiteboard.jpg", "/Users/owner/.dispatch-attachments/u1"));
        var stagedDoc = new DraftAttachment(
            Id: "att-doc-1",
            Kind: DraftKind.File,
            Name: "notes.txt",
            LocalFile: Path.Combine(_stores.Base, "notes.txt"),
            ByteSize: 128,
            PixelWidth: null,
            PixelHeight: null,
            Upload: new UploadState.Uploaded("/Users/owner/.dispatch-attachments/u2/notes.txt", "/Users/owner/.dispatch-attachments/u2"));

        var sending = chat.SendMemoAsync(memo, "check both", queued: false, attachments: [stagedPhoto, stagedDoc]);

        // Optimistic bubble shows the memo audio AND local attachment parts before submit finishes.
        var optimistic = chat.Messages[^1];
        Assert.True(optimistic.IsPending);
        Assert.Equal(2, optimistic.Parts.OfType<AttachmentPart>().Count());

        Assert.Equal(SendOutcome.Accepted, await sending);

        // image.attach ran for the photo, file.attach ran for the memo + doc, and prompt.submit sent one combined turn.
        var imgAttach = Assert.Single(socket.Calls("image.attach"));
        Assert.Equal("/Users/owner/.dispatch-attachments/u1/whiteboard.jpg", imgAttach.Str("path"));
        Assert.Equal(2, socket.Calls("file.attach").Count);

        var submit = Assert.Single(socket.Calls("prompt.submit"));
        var submitText = submit.Str("text")!;
        Assert.Contains("MEDIA:\"/Users/owner/.hermes/profiles/ivy/attachments/voice-memo.wav\"", submitText);
        Assert.Contains("Voice memo transcript: Pick up milk on the way home.", submitText);
        Assert.Contains("@file:/Users/owner/.hermes/profiles/ivy/attachments/notes.txt", submitText);
        Assert.Contains("check both", submitText);

        // Final user message keeps its attachment parts (switched to gateway source) alongside the rewritten memo text.
        var finalMsg = chat.Messages.Last(m => m.Role == Role.User);
        Assert.False(finalMsg.IsPending);
        var photoPart = Assert.Single(finalMsg.Parts.OfType<AttachmentPart>(), p => p.Attachment.IsImage);
        Assert.IsType<AttachmentSource.Gateway>(photoPart.Attachment.Source);
    }

    // =========================================================================
    // 2. VoiceChatRecordCodec & TalkController Transcript Card / Dedup
    // =========================================================================

    [Fact]
    public void VoiceChatRecordCodecFormatsMergesFiltersTruncatesParsesAndExtractsSpokenTurns()
    {
        // Adjacent same-speaker fragments merge cleanly.
        var turns = new List<VoiceTurn>();
        VoiceChatRecordCodec.AddFragment(turns, isUser: false, "Hi ");
        VoiceChatRecordCodec.AddFragment(turns, isUser: false, "there.");
        VoiceChatRecordCodec.AddFragment(turns, isUser: true, "What's on ");
        VoiceChatRecordCodec.AddFragment(turns, isUser: true, "my calendar?");
        VoiceChatRecordCodec.AddFragment(turns, isUser: false, "Two things: lunch at noon and a call at three.");
        Assert.Equal(3, turns.Count);

        var formatted = VoiceChatRecordCodec.FormatMessage(turns, TimeSpan.FromSeconds(252));
        Assert.NotNull(formatted);
        Assert.StartsWith("[Voice chat transcript · 4:12]\n(From the app", formatted);
        Assert.Contains("reply with exactly NO_REPLY.)", formatted);
        Assert.Contains("\nUser: What's on my calendar?\nVoice assistant: Two things: lunch at noon and a call at three.", formatted);
        Assert.True(VoiceChatRecordCodec.IsVoiceChatRecord(formatted));
        Assert.True(VoiceChatRecordCodec.IsVoiceChatRecord("  " + formatted + "  "));

        var card = VoiceChatRecordCodec.ParseCard(formatted);
        Assert.NotNull(card);
        Assert.Equal("Voice Chat · 4:12", card!.Value.Title);
        Assert.Equal("Voice: Hi there.\n\nYou: What's on my calendar?\n\nVoice: Two things: lunch at noon and a call at three.", card.Value.Body);
        Assert.DoesNotContain("From the app", card.Value.Body);
        Assert.DoesNotContain("NO_REPLY", card.Value.Body);

        // SpokenTurns strips header & bot note for future voice seeds.
        var spoken = VoiceChatRecordCodec.SpokenTurns(formatted!);
        Assert.Equal(3, spoken.Count);
        Assert.False(spoken[0].IsUser);
        Assert.Equal("Hi there.", spoken[0].Text);
        Assert.True(spoken[1].IsUser);
        Assert.Equal("What's on my calendar?", spoken[1].Text);
        Assert.False(spoken[2].IsUser);
        Assert.Equal("Two things: lunch at noon and a call at three.", spoken[2].Text);

        // Empty, assistant-only, whitespace-only, or stop-phrase-only conversations return null.
        Assert.Null(VoiceChatRecordCodec.FormatMessage([], TimeSpan.FromSeconds(10)));
        Assert.Null(VoiceChatRecordCodec.FormatMessage([new VoiceTurn(false, "Hello, I'm here.")], TimeSpan.FromSeconds(10)));
        Assert.Null(VoiceChatRecordCodec.FormatMessage([new VoiceTurn(false, "Hello."), new VoiceTurn(true, " Stop. ")], TimeSpan.FromSeconds(10)));
        Assert.Null(VoiceChatRecordCodec.FormatMessage([new VoiceTurn(true, "   ")], TimeSpan.FromSeconds(10)));

        // Non-records are rejected.
        Assert.False(VoiceChatRecordCodec.IsVoiceChatRecord(null));
        Assert.False(VoiceChatRecordCodec.IsVoiceChatRecord("What did we say in the voice chat?"));
        Assert.False(VoiceChatRecordCodec.IsVoiceChatRecord("[Voice chat transcript and more words"));
        Assert.False(VoiceChatRecordCodec.IsVoiceChatRecord("[Voice chat transcripts are great]"));
        Assert.Null(VoiceChatRecordCodec.ParseCard("[Voice chat transcripts are great]"));

        // Long conversation truncates oldest turns at MaxChars (24,000) with CutNote and formats H:MM:SS.
        var longTurns = new List<VoiceTurn>();
        var filler = string.Concat(Enumerable.Repeat("word ", 30));
        for (var i = 0; i < 400; i++)
            longTurns.Add(new VoiceTurn(i % 2 == 0, $"Turn number {i} {filler}"));

        var truncated = VoiceChatRecordCodec.FormatMessage(longTurns, TimeSpan.FromSeconds(3_700));
        Assert.NotNull(truncated);
        Assert.True(truncated!.Length < VoiceChatRecordCodec.MaxChars + 1_000);
        Assert.Contains(VoiceChatRecordCodec.CutNote, truncated);
        Assert.Contains("Turn number 399", truncated);
        Assert.DoesNotContain("Turn number 0 ", truncated);
        Assert.Equal("Voice Chat · 1:01:40", VoiceChatRecordCodec.ParseCard(truncated)?.Title);
        Assert.DoesNotContain(VoiceChatRecordCodec.SpokenTurns(truncated), t => t.Text.Contains(VoiceChatRecordCodec.CutNote));
    }

    [Fact]
    public async Task TalkControllerQueuesLiveVoiceRecordOnceAndStopsVoiceRecordTurnBeforeDelegation()
    {
        var capture = new StubTalkCapture();
        var speaker = new StubTalkSpeaker();
        var bridge = new RecordingTalkBridge();
        var gateway = new StubVoiceGateway();
        var prefs = new MemoryPrefs();
        StubLiveTransport? transport = null;

        using var ctrl = new TalkController(
            capture, speaker, prefs, gateway,
            liveFactory: () => transport = new StubLiveTransport());

        VoiceChatRecord? completed = null;
        ctrl.RecordCompleted += r => completed = r;

        await ctrl.StartAsync(bridge, TalkEngine.GptLive);
        transport!.Emit(new LiveServerEvent.SessionReady());
        ctrl.Tick(65);

        // Assistant & user exchange during live voice chat.
        transport.Emit(new LiveServerEvent.AssistantTextDelta("Hi, what can I do?"));
        transport.Emit(new LiveServerEvent.AssistantDone(null));
        transport.Emit(new LiveServerEvent.UserTranscriptFinal("Remind me about the launch."));
        transport.Emit(new LiveServerEvent.AssistantDone("Added a reminder for the launch."));

        // If the chat is currently answering a previous NO_REPLY voice record, delegating a real request stops it first.
        bridge.IsBusy = true;
        bridge.IsAnsweringVoiceRecord = true;
        transport.Emit(new LiveServerEvent.FunctionCall("call-1", "ask_agent", """{"request":"check launch status"}"""));
        Assert.True(await VoiceFixtures.WaitUntil(() => bridge.SentTurns.Contains("check launch status")));
        Assert.Equal(1, bridge.StopCalls);
        bridge.IsAnsweringVoiceRecord = false;
        bridge.CompleteReply("r-1", "Launch is on track.");

        // Ending queues the formatted voice chat transcript once (deduped on repeat End).
        ctrl.End(TalkEnd.User);
        ctrl.End(TalkEnd.User);

        Assert.True(await VoiceFixtures.WaitUntil(() => bridge.SentVoiceRecords.Count == 1));
        Assert.Single(bridge.SentVoiceRecords);
        Assert.NotNull(completed?.TranscriptMessage);
        Assert.Equal(bridge.SentVoiceRecords[0], completed!.TranscriptMessage);
        var card = VoiceChatRecordCodec.ParseCard(bridge.SentVoiceRecords[0]);
        Assert.NotNull(card);
        Assert.Equal("Voice Chat · 1:05", card!.Value.Title);
        Assert.Contains("You: Remind me about the launch.", card.Value.Body);
        Assert.Contains("Voice: Added a reminder for the launch.", card.Value.Body);
    }

    // =========================================================================
    // 3. Voice Hardening: M17 (Memo live words preservation) & M18 (Talk watchdog)
    // =========================================================================

    [Fact]
    public Task M17_MemoControllerPreservesLiveWordsOnNativeStoppedDraft() => MainLoop.Drive(async () =>
    {
        var accountId = $"memo-m17-{Guid.NewGuid()}";
        _stores.Activate(accountId);
        var file = _stores.Recording(accountId, seconds: 3);
        var capture = new FakeCapture(file);
        var listener = new StubLiveWordsListener("buy fresh apples");
        using var controller = new MemoController(capture, _stores.Stores, new MemoryPrefs());
        controller.MakeWords = () => listener;

        var target = new MemoTarget($"{accountId}|ivy|s1", null, null, "Ivy", MemoPaths.AccountKey(accountId));
        controller.MemoDown(target, 402);
        Assert.True(await VoiceFixtures.WaitUntil(() => controller.State.Phase == MemoPhase.Holding));

        listener.Emit(new LiveWordsText("buy fresh", "apples"));
        Assert.Equal("buy fresh apples", controller.Words);

        capture.NativeStop(MemoStopReason.Interrupted);

        Assert.Equal(MemoPhase.Idle, controller.State.Phase);
        var saved = _stores.Stores.Drafts?.Draft(target.Scope);
        Assert.NotNull(saved);
        Assert.False(listener.WasCancelled);
        Assert.True(listener.FinishCalled);
        Assert.Equal("buy fresh apples", saved!.Words);
    });

    [Fact]
    public async Task M18_TalkControllerWatchdogBreaksOutOfWedgedSpeechPlayback()
    {
        var capture = new StubTalkCapture();
        var wedgedSpeaker = new WedgedTalkSpeaker();
        var bridge = new RecordingTalkBridge();
        var gateway = new StubVoiceGateway { NextTranscript = "Read me a summary" };
        var prefs = new MemoryPrefs();

        using var ctrl = new TalkController(capture, wedgedSpeaker, prefs, gateway)
        {
            SpeechStallTimeout = TimeSpan.FromMilliseconds(120),
        };

        await ctrl.StartAsync(bridge, TalkEngine.Classic);
        Assert.Equal(TalkStatus.Listening, ctrl.Status);

        capture.EmitSpeechStarted();
        capture.EmitTake(new TalkTake(TalkWave.EncodeWav([400, -400]), 1.0));
        Assert.True(await VoiceFixtures.WaitUntil(() => bridge.SentTurns.Count == 1));

        var sw = Stopwatch.StartNew();
        bridge.CompleteReply("reply-1", "Here is your summary.");

        // Watchdog must break out of wedged Speaking well under 2 seconds, stop speaker, and return to Listening.
        Assert.True(await VoiceFixtures.WaitUntil(() => ctrl.Status == TalkStatus.Listening && wedgedSpeaker.StopCount > 0, seconds: 3));
        Assert.True(sw.Elapsed < TimeSpan.FromSeconds(2), $"Wedged speaker hung Talk for {sw.Elapsed}");
        Assert.Equal(TalkNoticeKind.SpeechFailed, ctrl.CurrentState.Notice?.Kind);

        // Live mode speaking watchdog via Tick also recovers from a missing AssistantDone.
        StubLiveTransport? transport = null;
        using var liveCtrl = new TalkController(
            new StubTalkCapture(), new StubTalkSpeaker(), new MemoryPrefs(), gateway,
            liveFactory: () => transport = new StubLiveTransport())
        {
            SpeechStallTimeout = TimeSpan.FromSeconds(5),
        };
        await liveCtrl.StartAsync(new RecordingTalkBridge(), TalkEngine.GptLive);
        transport!.Emit(new LiveServerEvent.SessionReady());
        transport.Emit(new LiveServerEvent.AssistantAudioDelta([1, 2, 3, 4]));
        Assert.Equal(TalkStatus.Speaking, liveCtrl.Status);
        liveCtrl.Tick(6.0);
        Assert.Equal(TalkStatus.Listening, liveCtrl.Status);
    }

    // =========================================================================
    // 4. samplehostClient Provisioning, H15 Repair, Optimize, Resolver & H6 404
    // =========================================================================

    [Fact]
    public void HasValidWebhookUrlAndPhoneConnectionResolverDetectTeXmlAndMissingFields()
    {
        Assert.True(samplehostApi.HasValidWebhookUrl(PhoneLimits.VoiceWebhookUrl));
        Assert.True(samplehostApi.HasValidWebhookUrl("https://hooks.example.com/samplehost"));
        Assert.False(samplehostApi.HasValidWebhookUrl(null));
        Assert.False(samplehostApi.HasValidWebhookUrl(""));
        Assert.False(samplehostApi.HasValidWebhookUrl("http://hooks.example.com/samplehost"));
        Assert.False(samplehostApi.HasValidWebhookUrl("https://localhost/hook"));
        Assert.False(samplehostApi.HasValidWebhookUrl("https://hooks.example.com/with space"));

        var missingWebhook = new samplehostCallControlAppSummary("c1", "App A", true, WebhookEventUrl: null, OutboundVoiceProfileId: "p1");
        var missingOutbound = new samplehostCallControlAppSummary("c2", "App B", true, PhoneLimits.VoiceWebhookUrl, OutboundVoiceProfileId: null);
        var emptyOutbound = new samplehostCallControlAppSummary("c3", "App C", true, PhoneLimits.VoiceWebhookUrl, OutboundVoiceProfileId: "");
        var healthy = new samplehostCallControlAppSummary("c4", "App D", true, PhoneLimits.VoiceWebhookUrl, OutboundVoiceProfileId: "p1");

        Assert.True(PhoneConnectionResolver.NeedsFix(missingWebhook));
        Assert.True(PhoneConnectionResolver.NeedsFix(missingOutbound));
        Assert.True(PhoneConnectionResolver.NeedsFix(emptyOutbound));
        Assert.False(PhoneConnectionResolver.NeedsFix(healthy));

        var texmlNumber = new samplehostNumber("+15550100101", ConnectionId: "texml-99", ConnectionName: "Assistant TeXML", Status: "active", Id: "num-1");
        IReadOnlyList<samplehostCallControlAppSummary> apps = [healthy];

        // Options lists only real Call Control apps when apps != null (never the TeXML connection).
        var opts = PhoneConnectionResolver.Options([texmlNumber], apps);
        Assert.Equal(new PhoneConnectionResolver.Option("c4", "App D"), Assert.Single(opts));

        // PreferredConnection skips TeXML connection on the number and picks the single real Call Control app.
        Assert.Equal("c4", PhoneConnectionResolver.PreferredConnection("+15550100101", [texmlNumber], apps));

        // TeXML detection & warning.
        Assert.True(PhoneConnectionResolver.IsInvalidSavedConnection("texml-99", apps));
        Assert.False(PhoneConnectionResolver.IsInvalidSavedConnection("c4", apps));
        var warnSaved = PhoneConnectionResolver.NonCallControlWarning(texmlNumber, "texml-99", apps);
        Assert.NotNull(warnSaved);
        Assert.Contains("TeXML", warnSaved);
        var warnNumber = PhoneConnectionResolver.NonCallControlWarning(texmlNumber, "", []);
        Assert.NotNull(warnNumber);
        Assert.Contains("Assistant TeXML", warnNumber);
    }

    [Fact]
    public async Task samplehostClientH6Preserves404NotFoundRedactsKeyAndHandlesCallStatus404()
    {
        var json404 = $$"""{"errors":[{"code":"10005","title":"Resource not found","detail":"Call not found for {{FakesamplehostKey}}"}]}""";
        var built = samplehostApi.BuildFailure(HttpStatusCode.NotFound, json404, FakesamplehostKey);
        Assert.True(built.IsNotFound);
        Assert.Equal(samplehostErrorKind.NotFound, built.Kind);
        Assert.DoesNotContain(FakesamplehostKey, built.Message);
        Assert.Contains("[redacted]", built.Message);
        Assert.True(samplehostApi.BuildFailure(HttpStatusCode.NotFound, "", FakesamplehostKey).IsNotFound);

        var handler = new StubHttpHandler((method, path, _) =>
        {
            if (method == "GET" && path == "/v2/calls/call-404")
                return (HttpStatusCode.NotFound, json404);
            if (method == "GET" && path == "/v2/call_control_applications/texml-app")
                return (HttpStatusCode.NotFound, """{"errors":[{"code":"10005","title":"Not found"}]}""");
            return (HttpStatusCode.OK, """{"data":{}}""");
        });

        using var api = new samplehostApi(samplehostEndpoint.Production, handler: handler);

        // CallStatusAsync treats JSON 404 as call ended (null) rather than throwing.
        Assert.Null(await api.CallStatusAsync(FakesamplehostKey, "call-404"));

        // CallControlAppAsync preserves NotFound (H6) instead of swallowing it.
        var ex = await Assert.ThrowsAsync<samplehostException>(() => api.CallControlAppAsync(FakesamplehostKey, "texml-app"));
        Assert.True(ex.IsNotFound);
    }

    [Fact]
    public async Task samplehostClientProvisionRepairH15AndOptimizeAssistantWorkEndToEnd()
    {
        const string customWebhook = "https://hooks.example.com/samplehost-voice";
        const string staleWebhook = "https://stale.example.com/old-webhook";
        var patchedWebhooks = new List<string>();
        JsonObject? optimizedPayload = null;
        string? assignedConn = null;

        var handler = new StubHttpHandler((method, path, body) =>
        {
            var json = string.IsNullOrWhiteSpace(body) ? null : J.Parse(body) as JsonObject;
            return (method, path) switch
            {
                ("GET", "/v2/outbound_voice_profiles") => (HttpStatusCode.OK, """{"data":[]}"""),
                ("POST", "/v2/outbound_voice_profiles") => (HttpStatusCode.OK, """{"data":{"id":"prof-new","name":"Hermes HQ Outbound","enabled":true,"whitelisted_destinations":["US"]}}"""),
                ("POST", "/v2/call_control_applications") => (HttpStatusCode.OK,
                    $$$$"""{"data":{"id":"app-new","application_name":"Hermes HQ Voice","active":true,"webhook_event_url":"{{{{json.Text("webhook_event_url")}}}}","outbound":{"outbound_voice_profile_id":"prof-new"}}}"""),
                ("PATCH", "/v2/phone_numbers/num-1") => HandleAssign(json),
                ("GET", "/v2/call_control_applications/conn-1") => (HttpStatusCode.OK,
                    $$$$"""{"data":{"id":"conn-1","application_name":"Voice App","active":true,"webhook_event_url":"{{{{staleWebhook}}}}","outbound":{"outbound_voice_profile_id":"prof-1"}}}"""),
                ("GET", "/v2/outbound_voice_profiles/prof-1") => (HttpStatusCode.OK,
                    """{"data":{"id":"prof-1","name":"Default","enabled":true,"whitelisted_destinations":["US"]}}"""),
                ("PATCH", "/v2/call_control_applications/conn-1") => HandlePatchApp(json),
                ("GET", "/v2/ai/assistants/asst-1") => (HttpStatusCode.OK,
                    """{"data":{"id":"asst-1","name":"Otto","model":"meta-llama/Meta-Llama-3.1-70B-Instruct","enabled_features":["telephony"],"transcription":{"model":"whisper"},"interruption_settings":{"enable":false},"telephony_settings":{"default_texml_app_id":"texml-keep","noise_suppression":"krisp","greeting_delay_ms":1500,"user_idle_timeout_secs":30,"user_idle_reply_secs":10,"recording_settings":{"enabled":false}}}}"""),
                ("POST", "/v2/ai/assistants/asst-1") => HandleOptimize(json),
                _ => (HttpStatusCode.NotFound, """{"errors":[{"code":"10005","title":"Not found"}]}"""),
            };
        });

        (HttpStatusCode, string) HandleAssign(JsonObject? json)
        {
            assignedConn = json.Text("connection_id");
            return (HttpStatusCode.OK, $$$"""{"data":{"id":"num-1","phone_number":"+15550100102","status":"active","connection_id":"{{{assignedConn}}}"}}""");
        }

        (HttpStatusCode, string) HandlePatchApp(JsonObject? json)
        {
            var url = json.Text("webhook_event_url") ?? "";
            patchedWebhooks.Add(url);
            return (HttpStatusCode.OK, $$$$"""{"data":{"id":"conn-1","application_name":"Voice App","active":true,"webhook_event_url":"{{{{url}}}}","outbound":{"outbound_voice_profile_id":"prof-1"}}}""");
        }

        (HttpStatusCode, string) HandleOptimize(JsonObject? json)
        {
            optimizedPayload = json;
            return (HttpStatusCode.OK, """{"data":{"id":"asst-1"}}""");
        }

        using var api = new samplehostApi(samplehostEndpoint.Production, handler: handler);
        var number = new samplehostNumber("+15550100102", ConnectionId: "old-texml", Status: "active", Id: "num-1");

        // ProvisionVoiceConnectionAsync creates profile + Call Control app + assigns number.
        var (provisionedApp, updatedNum) = await api.ProvisionVoiceConnectionAsync(FakesamplehostKey, number);
        Assert.Equal("app-new", provisionedApp.Id);
        Assert.Equal("app-new", assignedConn);
        Assert.Equal("app-new", updatedNum?.ConnectionId);

        // H15: explicit custom webhook overrides stale existing webhook_event_url.
        var sameConnNumber = number with { ConnectionId = "conn-1" };
        await api.RepairVoiceConnectionAsync(FakesamplehostKey, "conn-1", sameConnNumber, customWebhook);
        Assert.Equal(new[] { customWebhook }, patchedWebhooks);

        // H15: default placeholder preserves an existing valid https:// webhook URL.
        patchedWebhooks.Clear();
        await api.RepairVoiceConnectionAsync(FakesamplehostKey, "conn-1", sameConnNumber);
        Assert.Equal(new[] { staleWebhook }, patchedWebhooks);

        // OptimizeAssistantAsync sends deepgram/flux, aicoustics, greeting_delay_ms:400, interruption_settings,
        // user_idle_reply_secs:5, and preserves unknown telephony_settings keys (default_texml_app_id).
        await api.OptimizeAssistantAsync(FakesamplehostKey, "asst-1", recording: true);
        Assert.NotNull(optimizedPayload);
        Assert.Equal("deepgram/flux", optimizedPayload.Obj("transcription").Text("model"));
        Assert.Equal(true, optimizedPayload.Obj("interruption_settings")?.Bool("enable"));
        var tel = optimizedPayload.Obj("telephony_settings");
        Assert.Equal("aicoustics", tel.Text("noise_suppression"));
        Assert.Equal(400L, tel?.Int("greeting_delay_ms"));
        Assert.Equal(5L, tel?.Int("user_idle_reply_secs"));
        Assert.Equal(true, tel.Obj("recording_settings")?.Bool("enabled"));
        Assert.Equal("texml-keep", tel.Text("default_texml_app_id"));
    }

    // =========================================================================
    // 5. PhoneSetupCheck (H6 404 -> TeXML fail, H14 webhook / status / quality)
    // =========================================================================

    [Fact]
    public async Task PhoneSetupCheckFlagsH6NotFoundAndH14WebhookStatusConnectionAndQualityIssues()
    {
        var setup = new PhoneSetup
        {
            FromNumber = "+15550100105",
            ConnectionId = "conn-1",
            AssistantId = "asst-1",
            RecordCalls = false,
        };

        // H6: RunAsync catches 404 on CallControlAppAsync and AssistantAsync as Fail (not Unknown).
        var handler404 = new StubHttpHandler((method, path, _) => (method, path) switch
        {
            ("GET", "/v2/phone_numbers") => (HttpStatusCode.OK,
                """{"data":[{"id":"n1","phone_number":"+15550100105","status":"active","connection_id":"conn-1"}]}"""),
            ("GET", "/v2/call_control_applications/conn-1") => (HttpStatusCode.NotFound,
                """{"errors":[{"code":"10005","title":"Resource not found"}]}"""),
            ("GET", "/v2/ai/assistants/asst-1") => (HttpStatusCode.NotFound,
                """{"errors":[{"code":"10005","title":"Resource not found"}]}"""),
            ("GET", "/v2/balance") => (HttpStatusCode.OK, """{"data":{"balance":"25.00","currency":"USD"}}"""),
            _ => (HttpStatusCode.NotFound, "{}"),
        });
        using var api404 = new samplehostApi(samplehostEndpoint.Production, handler: handler404);
        var rows404 = await PhoneSetupCheck.RunAsync(api404, FakesamplehostKey, setup);
        var connRow = rows404.First(r => r.Id == "connection");
        Assert.Equal(PhoneSetupCheckState.Fail, connRow.State);
        Assert.Contains("TeXML", connRow.Detail);
        Assert.Equal(PhoneSetupCheckState.Fail, rows404.First(r => r.Id == "assistant").State);

        // H14: nil webhook_event_url fails connection; inactive status & connection mismatch fail from;
        // suboptimal assistant settings emit "voice" Warn row.
        var badAssistant = new samplehostAssistantDetail(
            Id: "asst-1",
            Name: "Otto",
            Model: "openai/gpt-live",
            TelephonyEnabled: true,
            RecordingEnabled: false,
            TranscriptionModel: "whisper",
            InterruptionEnabled: false,
            UserIdleTimeoutSecs: 25,
            UserIdleReplySecs: 9,
            GreetingDelayMs: 1800,
            NoiseSuppression: "krisp");
        Assert.Equal(6, badAssistant.CallQualityIssues.Count);

        var rowsH14 = PhoneSetupCheck.Evaluate(setup, hasKey: true, new PhoneSetupCheckReads
        {
            Numbers = [new samplehostNumber("+15550100105", ConnectionId: "other-conn", Status: "active", Id: "n1")],
            Connection = new samplehostCallControlApp("conn-1", "Voice App", "prof-1", Active: true, WebhookEventUrl: null),
            VoiceProfile = new samplehostVoiceProfile("prof-1", "US", ["US"], Enabled: true),
            Assistant = badAssistant,
            Balance = new samplehostBalance(20m, "USD"),
        });
        Assert.Equal(PhoneSetupCheckState.Fail, rowsH14.First(r => r.Id == "from").State);
        Assert.Contains("voice connection", rowsH14.First(r => r.Id == "from").Detail);
        Assert.Equal(PhoneSetupCheckState.Fail, rowsH14.First(r => r.Id == "connection").State);
        Assert.Contains("webhook", rowsH14.First(r => r.Id == "connection").Detail);
        Assert.Equal(PhoneSetupCheckState.Warn, rowsH14.First(r => r.Id == "model").State);
        Assert.Equal(PhoneSetupCheckState.Warn, rowsH14.First(r => r.Id == "voice").State);

        // Inactive number status fails "from".
        var rowsInactive = PhoneSetupCheck.Evaluate(setup, hasKey: true, new PhoneSetupCheckReads
        {
            Numbers = [new samplehostNumber("+15550100105", ConnectionId: "conn-1", Status: "purchase-pending", Id: "n1")],
            Connection = new samplehostCallControlApp("conn-1", "Voice App", "prof-1", Active: true, WebhookEventUrl: PhoneLimits.VoiceWebhookUrl),
            VoiceProfile = new samplehostVoiceProfile("prof-1", "US", ["US"], Enabled: true),
            Assistant = new samplehostAssistantDetail("asst-1", "Otto", "openai/gpt-4o", true, false,
                TranscriptionModel: "deepgram/flux", InterruptionEnabled: true, UserIdleTimeoutSecs: 180,
                UserIdleReplySecs: 5, GreetingDelayMs: 400, NoiseSuppression: "aicoustics"),
            Balance = new samplehostBalance(20m, "USD"),
        });
        Assert.Equal(PhoneSetupCheckState.Fail, rowsInactive.First(r => r.Id == "from").State);
        Assert.Contains("purchase-pending", rowsInactive.First(r => r.Id == "from").Detail);
        Assert.Equal(PhoneSetupCheckState.Pass, rowsInactive.First(r => r.Id == "connection").State);
        Assert.DoesNotContain(rowsInactive, r => r.Id == "voice");
    }

    // =========================================================================
    // Test Doubles
    // =========================================================================

    private sealed class StubLiveWordsListener(string finalText) : ILiveWordsListening
    {
        public LiveWordsSource Source => LiveWordsSource.Device;
        public bool IsAvailable => true;
        public bool WasCancelled { get; private set; }
        public bool FinishCalled { get; private set; }
        public event Action<LiveWordsText>? Changed;

        public Task<bool> StartAsync(CancellationToken ct = default) => Task.FromResult(true);
        public void FeedPcm(ReadOnlySpan<short> pcm, int sampleRate) { }
        public void Emit(LiveWordsText text) => Changed?.Invoke(text);

        public Task<string> FinishAsync(CancellationToken ct = default)
        {
            FinishCalled = true;
            return Task.FromResult(finalText);
        }

        public void Cancel() => WasCancelled = true;
    }

    private sealed class StubTalkCapture : ITalkCapturing
    {
        public bool IsCapturing { get; private set; }
        public bool IsMuted { get; set; }
        public bool BargeInEnabled { get; set; }
        public int SampleRate => 16000;
        public event Action<double>? LevelChanged;
        public event Action? SpeechStarted;
        public event Action<TalkTake>? TakeCompleted;
        public event Action? BargeInDetected;
        public event Action<short[]>? PcmCaptured;
        public event Action<TalkCaptureError, string>? Failed;

        public Task StartAsync(CancellationToken ct = default) { IsCapturing = true; return Task.CompletedTask; }
        public TalkTake? FlushNow() => null;
        public void Stop() => IsCapturing = false;
        public void Dispose() => Stop();
        public void EmitSpeechStarted() => SpeechStarted?.Invoke();
        public void EmitTake(TalkTake take) => TakeCompleted?.Invoke(take);
        public void EmitUnused() { LevelChanged?.Invoke(0); BargeInDetected?.Invoke(); PcmCaptured?.Invoke([]); Failed?.Invoke(TalkCaptureError.MeterStalled, ""); }
    }

    private sealed class StubTalkSpeaker : ITalkSpeaker
    {
        public bool IsSpeaking { get; private set; }
        public event Action<double>? LevelChanged;
        public Task<TalkSpeechOutcome> SpeakAsync(string text, Func<string, CancellationToken, Task<SpeechClip>>? gatewaySpeak, CancellationToken ct = default)
        {
            LevelChanged?.Invoke(0.5);
            return Task.FromResult(TalkSpeechOutcome.Completed);
        }
        public void PlayPcmChunk(ReadOnlySpan<byte> pcm24k) { }
        public void FlushPcm() { }
        public void Stop() => IsSpeaking = false;
        public void Dispose() { }
    }

    /// Simulates a wedged TTS playback that ignores cancellation and never finishes on its own (M18).
    private sealed class WedgedTalkSpeaker : ITalkSpeaker
    {
        public bool IsSpeaking { get; private set; }
        public int StopCount { get; private set; }
        public event Action<double>? LevelChanged;

        public Task<TalkSpeechOutcome> SpeakAsync(string text, Func<string, CancellationToken, Task<SpeechClip>>? gatewaySpeak, CancellationToken ct = default)
        {
            IsSpeaking = true;
            _ = LevelChanged;
            return new TaskCompletionSource<TalkSpeechOutcome>(TaskCreationOptions.RunContinuationsAsynchronously).Task;
        }

        public void PlayPcmChunk(ReadOnlySpan<byte> pcm24k) { }
        public void FlushPcm() { }
        public void Stop() { IsSpeaking = false; StopCount++; }
        public void Dispose() { }
    }

    private sealed class RecordingTalkBridge : ITalkChatBridge
    {
        public string Scope => "acct|ivy|chat-3d";
        public string Profile => "ivy";
        public string BotName => "Ivy";
        public bool IsBusy { get; set; }
        public bool IsAnsweringVoiceRecord { get; set; }
        public List<string> SentTurns { get; } = [];
        public List<string> SentVoiceRecords { get; } = [];
        public int StopCalls { get; private set; }
        private SpokenReply? _reply;
        public event Action? Changed;

        public SpokenReply? NewestReply() => _reply;
        public IReadOnlyList<(string Role, string Text)> RecentHistory(int maxMessages = 10) => [];

        public Task<SendOutcome> SendTurnAsync(string text, CancellationToken ct = default)
        {
            SentTurns.Add(text);
            IsBusy = true;
            return Task.FromResult(SendOutcome.Accepted);
        }

        public Task<SendOutcome> SendVoiceRecordAsync(string text, CancellationToken ct = default)
        {
            SentVoiceRecords.Add(text);
            return Task.FromResult(SendOutcome.Accepted);
        }

        public Task StopTurnAsync()
        {
            StopCalls++;
            IsBusy = false;
            return Task.CompletedTask;
        }

        public void CompleteReply(string id, string text)
        {
            _reply = new SpokenReply(id, text, Pending: false);
            IsBusy = false;
            Changed?.Invoke();
        }
    }

    private sealed class StubVoiceGateway : IVoiceGateway
    {
        public string NextTranscript { get; set; } = "Hello";
        public Task<TalkConfig> ConfigAsync(string? profile, CancellationToken ct = default) =>
            Task.FromResult(new TalkConfig(true, true, LiveOffered: true, GrokOffered: true));
        public Task<string> TranscribeAsync(byte[] audio, string mime, string? profile, CancellationToken ct = default) =>
            Task.FromResult(NextTranscript);
        public Task<SpeechClip> SpeakAsync(string text, string? voice, string? profile, CancellationToken ct = default) =>
            Task.FromResult(new SpeechClip(TalkWave.EncodeWav([100, -100]), "audio/wav", text));
        public Task<LiveVoiceStatus> LiveStatusAsync(string? profile, CancellationToken ct = default) =>
            Task.FromResult(new LiveVoiceStatus(true, true, "alloy", "gpt-4o-realtime"));
        public Task<VoiceLease> LiveSessionAsync(string? profile, string? voice, CancellationToken ct = default) =>
            Task.FromResult(new VoiceLease("tok", new Uri("wss://example.invalid/realtime"), "gpt-4o-realtime", voice ?? "alloy", null));
        public Task<GrokLiveStatus> GrokStatusAsync(string? profile, CancellationToken ct = default) =>
            Task.FromResult(new GrokLiveStatus(true, true, "Ara"));
        public Task<GrokLiveSession> GrokSessionAsync(string? profile, string? voice, CancellationToken ct = default) =>
            Task.FromResult(new GrokLiveSession("tok", GrokLiveSession.DefaultEndpoint, voice ?? "Ara"));
    }

    private sealed class StubLiveTransport : ILiveVoiceTransport
    {
        public event Action<LiveServerEvent>? EventReceived;
        public Task ConnectAsync(TalkEngine engine, VoiceLease? gptLease, GrokLiveSession? grokSession, string instructions, CancellationToken ct = default) => Task.CompletedTask;
        public Task SendAudioAsync(ReadOnlyMemory<byte> pcm24k, CancellationToken ct = default) => Task.CompletedTask;
        public Task SendControlAsync(string json, CancellationToken ct = default) => Task.CompletedTask;
        public Task CloseAsync(CancellationToken ct = default) => Task.CompletedTask;
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
        public void Emit(LiveServerEvent ev) => EventReceived?.Invoke(ev);
    }

    private sealed class StubHttpHandler(Func<string, string, string?, (HttpStatusCode Status, string Body)> responder) : HttpMessageHandler
    {
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var body = request.Content != null ? await request.Content.ReadAsStringAsync(cancellationToken) : null;
            var (status, respBody) = responder(request.Method.Method, request.RequestUri!.AbsolutePath, body);
            return new HttpResponseMessage(status)
            {
                Content = new StringContent(respBody, Encoding.UTF8, "application/json"),
            };
        }
    }

    private sealed class MiniLoopback : IAsyncDisposable
    {
        private readonly HttpListener _http = new();
        private readonly CancellationTokenSource _life = new();
        private readonly object _gate = new();
        private readonly List<(string Method, JsonObject Params)> _log = [];
        public string Url { get; }

        public MiniLoopback()
        {
            var probe = new TcpListener(IPAddress.Loopback, 0);
            probe.Start();
            var port = ((IPEndPoint)probe.LocalEndpoint).Port;
            probe.Stop();
            Url = $"http://127.0.0.1:{port}";
            _http.Prefixes.Add(Url + "/");
            _http.Start();
            _ = Task.Run(ServeAsync);
        }

        public IReadOnlyList<JsonObject> Calls(string method)
        {
            lock (_gate) return [.. _log.Where(e => e.Method == method).Select(e => e.Params)];
        }

        private async Task ServeAsync()
        {
            while (!_life.IsCancellationRequested)
            {
                HttpListenerContext ctx;
                try { ctx = await _http.GetContextAsync(); } catch { return; }
                _ = Task.Run(() => HandleAsync(ctx));
            }
        }

        private async Task HandleAsync(HttpListenerContext ctx)
        {
            var path = ctx.Request.Url!.AbsolutePath;
            if (path == "/api/auth/ws-ticket")
            {
                var bytes = Encoding.UTF8.GetBytes("""{"ticket":"synthetic-ticket"}""");
                ctx.Response.ContentType = "application/json";
                ctx.Response.ContentLength64 = bytes.Length;
                await ctx.Response.OutputStream.WriteAsync(bytes);
                ctx.Response.Close();
                return;
            }
            if (path != "/api/ws" || !ctx.Request.IsWebSocketRequest)
            {
                ctx.Response.StatusCode = 404;
                ctx.Response.Close();
                return;
            }
            var ws = (await ctx.AcceptWebSocketAsync(null)).WebSocket;
            async Task SendAsync(JsonNode node)
            {
                try { await ws.SendAsync(Encoding.UTF8.GetBytes(node.ToJsonString()), WebSocketMessageType.Text, true, CancellationToken.None); }
                catch (Exception) { }
            }
            await SendAsync(new JsonObject
            {
                ["jsonrpc"] = "2.0",
                ["method"] = "event",
                ["params"] = new JsonObject { ["type"] = "gateway.ready", ["payload"] = new JsonObject { ["replay_epoch"] = "e1" } },
            });
            var buffer = new byte[256 * 1024];
            while (ws.State == WebSocketState.Open && !_life.IsCancellationRequested)
            {
                using var frame = new MemoryStream();
                try
                {
                    WebSocketReceiveResult r;
                    do
                    {
                        r = await ws.ReceiveAsync(buffer, _life.Token);
                        if (r.MessageType == WebSocketMessageType.Close) return;
                        frame.Write(buffer, 0, r.Count);
                    } while (!r.EndOfMessage);
                }
                catch { return; }
                if (JsonNode.Parse(Encoding.UTF8.GetString(frame.ToArray())) is not JsonObject req) continue;
                var method = req["method"]?.GetValue<string>() ?? "";
                var parameters = req["params"] as JsonObject ?? [];
                lock (_gate) _log.Add((method, (JsonObject)parameters.DeepClone()));
                if (req["id"] is not { } id) continue;

                JsonNode result = method switch
                {
                    "session.resume" => new JsonObject { ["session_id"] = VoiceFakeClient.Rid },
                    "image.attach" => new JsonObject { ["attached"] = true, ["path"] = parameters.Str("path") ?? "/stored/photo.jpg", ["width"] = 1200, ["height"] = 800 },
                    "file.attach" => VoiceFakeClient.DefaultCall(method, parameters, 1),
                    "prompt.submit" => new JsonObject { ["user_row_id"] = 101 },
                    _ => new JsonObject(),
                };
                await SendAsync(new JsonObject { ["jsonrpc"] = "2.0", ["id"] = id.DeepClone(), ["result"] = result });
            }
        }

        public ValueTask DisposeAsync()
        {
            _life.Cancel();
            try { _http.Close(); } catch (ObjectDisposedException) { }
            return ValueTask.CompletedTask;
        }
    }
}
