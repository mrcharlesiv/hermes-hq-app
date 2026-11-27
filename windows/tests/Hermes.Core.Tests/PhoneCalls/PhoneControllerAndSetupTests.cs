using Hermes.Core.PhoneCalls;

namespace Hermes.Core.Tests.PhoneCalls;

public class PhoneControllerAndSetupTests
{
    private const string FakeSecret = "KEY019999_FAKE_TEST_SECRET_TOKEN";

    [Theory]
    [InlineData("https://api.samplehost.com/v2", false, true)]
    [InlineData("http://api.samplehost.com/v2", false, false)]
    [InlineData("https://evil.example.com/v2", false, false)]
    [InlineData("https://127.0.0.1:8443/v2", false, false)]
    [InlineData("https://127.0.0.1:8443/v2", true, true)]
    public void samplehostEndpointPolicyEnforcesStrictHostValidation(string url, bool allowLoopback, bool expected)
    {
        Assert.Equal(expected, samplehostEndpoint.IsAllowed(new Uri(url), allowLoopback));
    }

    [Fact]
    public async Task ControllerDrivesFullLifecycleHoldMuteAnswerAndResultDelivery()
    {
        var now = new DateTimeOffset(2026, 11, 24, 14, 0, 0, TimeSpan.Zero);
        var api = new FakesamplehostApi();
        var keys = new MemoryPhoneKeyStore();
        keys.SaveKey("acct-1", FakeSecret);
        var history = new MemoryPhoneHistoryStore();
        var ctrl = new PhoneCallController("acct-1", api, keys, history, clock: () => now);
        ctrl.SaveSetup(new PhoneSetup
        {
            FromNumber = "+15550100100",
            ConnectionId = "conn-1",
            AssistantId = "asst-1",
            OwnerName = "Otto",
            RecordCalls = true,
            SendResultsToChat = true,
        });

        var dialed = await ctrl.DialAsync(new PhoneStartIntent("+1 (555) 010-0123", "Confirm Tuesday slot", "Dental Clinic",
            ChatProfile: "otto", ChatSessionId: "sess-1"));
        Assert.Equal(PhoneCallState.Ringing, dialed.State);
        Assert.True(api.MatchedRecordingBeforeDial);
        Assert.Equal("+15550100123", api.LastDial!.To);

        // Connected with live transcript + ask_owner question
        api.Status = new samplehostCallStatus("ctrl-1", IsAlive: true, State: "active", AnsweredAt: now.AddSeconds(5));
        api.ConvId = "conv-1";
        api.Msgs =
        [
            new samplehostMessage("1", "assistant", "Hi, calling for Otto."),
            new samplehostMessage("2", "assistant", "", ToolCalls: [new samplehostToolCall("tc-1", "ask_owner", """{"question":"Confirm 10 AM?","choices":["Yes","No"]}""")]),
        ];
        now = now.AddSeconds(10);
        var live = await ctrl.RefreshActiveAsync();
        Assert.Equal(PhoneCallState.Connected, live!.State);
        Assert.Equal("Call needs you", PhoneChipWords.From(live, now).Text);

        // Answer question & whisper
        await ctrl.AnswerQuestionAsync("tc-1", "Yes");
        Assert.Equal("Yes", api.LastToolAnswer);
        await ctrl.TellAssistantAsync("Say thanks.");
        Assert.Equal("Say thanks.", api.LastOwnerMessage);

        // Mute & Hold
        await ctrl.ToggleMuteAsync();
        Assert.True(ctrl.ActiveCall!.IsMuted);
        await ctrl.ToggleHoldAsync();
        Assert.Equal(PhoneCallState.OnHold, ctrl.ActiveCall.State);
        Assert.StartsWith("On hold · ", PhoneChipWords.From(ctrl.ActiveCall, now).Text);
        await ctrl.ToggleHoldAsync();
        Assert.Equal(PhoneCallState.Connected, ctrl.ActiveCall.State);

        // Call ends cleanly & delivers result once to originating chat
        api.Status = new samplehostCallStatus("ctrl-1", IsAlive: false, State: "ended", HangupCause: "normal_clearing");
        api.Summary = new samplehostConversationInsight("Appointment booked for Tuesday at 10 AM.");
        now = now.AddSeconds(50);
        var ended = await ctrl.RefreshActiveAsync();
        Assert.Equal(PhoneCallState.Ended, ended!.State);
        Assert.Equal(PhoneOutcomeKind.Finished, ended.Outcome!.Kind);
        Assert.Single(ctrl.History);

        string? posted = null;
        var delivered = await ctrl.DeliverPendingResultsAsync((profile, sid, body) =>
        {
            posted = body;
            return Task.FromResult(profile == "otto" && sid == "sess-1");
        });
        Assert.Equal(1, delivered);
        Assert.NotNull(posted);
        Assert.DoesNotContain(FakeSecret, posted);
        var parsedCard = PhoneResultCard.TryParse(posted);
        Assert.NotNull(parsedCard);
        Assert.Contains("Appointment booked", parsedCard!.Summary);

        // Second delivery pass is a no-op
        Assert.Equal(0, await ctrl.DeliverPendingResultsAsync((_, _, _) => Task.FromResult(true)));
    }

    [Fact]
    public async Task ControllerEnforcesSafetyStopAndRingTimeout()
    {
        var now = new DateTimeOffset(2026, 11, 24, 14, 0, 0, TimeSpan.Zero);
        var api = new FakesamplehostApi();
        var keys = new MemoryPhoneKeyStore();
        keys.SaveKey("acct-2", FakeSecret);
        var ctrl = new PhoneCallController("acct-2", api, keys, new MemoryPhoneHistoryStore(), clock: () => now);
        ctrl.SaveSetup(new PhoneSetup { FromNumber = "+15550100100", ConnectionId = "c1", AssistantId = "a1" });

        await ctrl.DialAsync(new PhoneStartIntent("+15550100123", "Test ring timeout"));
        api.Status = new samplehostCallStatus("ctrl-1", IsAlive: true, State: "ringing");
        now = now.AddSeconds(PhoneLimits.RingTimeoutSeconds + 1);
        var timedOut = await ctrl.RefreshActiveAsync();
        Assert.Equal(PhoneCallState.Ended, timedOut!.State);
        Assert.Equal(PhoneOutcomeKind.NoAnswer, timedOut.Outcome!.Kind);
        Assert.Equal(PhoneLocalEnd.RingTimeout, timedOut.LocalEnd);
    }

    [Fact]
    public void SetupCheckEvaluatesAllDiagnosticsAndRedactsSecretsInShares()
    {
        var setup = new PhoneSetup
        {
            FromNumber = "+15550100100",
            ConnectionId = "conn-1",
            AssistantId = "asst-1",
            RecordCalls = true,
        };
        var reads = new PhoneSetupCheckReads
        {
            Numbers = [new samplehostNumber("+15550100100", "conn-1")],
            Connection = new samplehostCallControlApp("conn-1", "Hermes Voice", "prof-1", Active: true),
            VoiceProfile = new samplehostVoiceProfile("prof-1", "US Only", ["US"], Enabled: true),
            Assistant = new samplehostAssistantDetail("asst-1", "Hermes Caller", "gpt-4o-mini-realtime", TelephonyEnabled: true, RecordingEnabled: false),
            Balance = new samplehostBalance(0.50m, "USD"),
            DestinationNumber = "+442079460958",
        };
        var rows = PhoneSetupCheck.Evaluate(setup, hasKey: true, reads);
        Assert.Equal(PhoneSetupCheckState.Pass, rows.First(r => r.Id == "key").State);
        Assert.Equal(PhoneSetupCheckState.Fail, rows.First(r => r.Id == "profile").State); // GB not in ["US"]
        Assert.Equal(PhoneSetupCheckState.Warn, rows.First(r => r.Id == "model").State);   // realtime model warning
        Assert.Equal(PhoneSetupCheckState.Warn, rows.First(r => r.Id == "recording").State);
        Assert.Equal(PhoneSetupCheckState.Warn, rows.First(r => r.Id == "balance").State);

        var call = new PhoneCallRecord
        {
            Id = "c1",
            AccountId = "a",
            To = "+15550100123",
            Goal = "Check hours",
            State = PhoneCallState.Ended,
            Error = $"Auth failed with {FakeSecret}",
            Outcome = PhoneOutcome.CouldNotConnect($"Bad key {FakeSecret}"),
        };
        var shared = PhoneCallPresentation.ShareText(call, FakeSecret);
        Assert.DoesNotContain(FakeSecret, shared);
        Assert.Contains("[redacted]", shared);
    }

    [Fact]
    public void ProposalLinksAndChatNotesEnforceSecurityRules()
    {
        var uri = "hermes://phone-call?to=%2B15550100123&goal=Book+table&name=Bistro&voicemail=leave";
        var parsed = PhoneProposal.TryParse(uri, fromChat: true);
        Assert.NotNull(parsed);
        Assert.Equal("+15550100123", parsed!.To);
        Assert.Equal("Book table", parsed.Goal);
        Assert.Equal("Bistro", parsed.Name);
        Assert.Equal(PhoneVoicemailChoice.LeaveMessage, parsed.Voicemail);

        // Must refuse links from outside chat!
        Assert.Null(PhoneProposal.TryParse(uri, fromChat: false));
        Assert.Null(PhoneProposal.TryParse("hermes://phone-call?to=bad&goal=hi", fromChat: true));
        Assert.Null(PhoneProposal.TryParse("hermes://phone-call?to=%2B15550100123", fromChat: true));

        Assert.True(PhoneChatNote.ShouldAttach("Please call the clinic for me", phoneReady: true));
        Assert.False(PhoneChatNote.ShouldAttach("Please call the clinic for me", phoneReady: false));
        var attached = PhoneChatNote.Attach("Please call the clinic");
        Assert.Equal("Please call the clinic", PhoneChatNote.Strip(attached));
    }

    private sealed class FakesamplehostApi : IsamplehostApi
    {
        public bool MatchedRecordingBeforeDial { get; private set; }
        public PhoneDialRequest? LastDial { get; private set; }
        public samplehostCallStatus? Status { get; set; }
        public string? ConvId { get; set; }
        public IReadOnlyList<samplehostMessage> Msgs { get; set; } = [];
        public samplehostConversationInsight? Summary { get; set; }
        public string? LastToolAnswer { get; private set; }
        public string? LastOwnerMessage { get; private set; }
        private bool _matchedRecording;

        public Task<IReadOnlyList<samplehostNumber>> PhoneNumbersAsync(string apiKey, CancellationToken ct = default) => Task.FromResult<IReadOnlyList<samplehostNumber>>([]);
        public Task<IReadOnlyList<samplehostNumber>> AllPhoneNumbersAsync(string apiKey, CancellationToken ct = default) => Task.FromResult<IReadOnlyList<samplehostNumber>>([]);
        public Task<IReadOnlyList<samplehostAssistant>> AssistantsAsync(string apiKey, CancellationToken ct = default) => Task.FromResult<IReadOnlyList<samplehostAssistant>>([]);
        public Task<samplehostAssistant> CreateAssistantAsync(string apiKey, string name, string ownerName, string? voice = null, CancellationToken ct = default) =>
            Task.FromResult(new samplehostAssistant("asst-new", name));
        public Task<samplehostAssistantDetail?> AssistantAsync(string apiKey, string assistantId, CancellationToken ct = default) => Task.FromResult<samplehostAssistantDetail?>(null);
        public Task UpdateTelephonyAsync(string apiKey, string assistantId, bool enabled, CancellationToken ct = default) => Task.CompletedTask;
        public Task MatchRecordingAsync(string apiKey, string assistantId, bool recordCalls, CancellationToken ct = default)
        {
            _matchedRecording = true;
            return Task.CompletedTask;
        }
        public Task<samplehostDialed> DialAsync(string apiKey, PhoneDialRequest request, CancellationToken ct = default)
        {
            MatchedRecordingBeforeDial = _matchedRecording;
            LastDial = request;
            return Task.FromResult(new samplehostDialed("ctrl-1", "leg-1"));
        }
        public Task<string?> ConversationIdAsync(string apiKey, string callControlId, CancellationToken ct = default) => Task.FromResult(ConvId);
        public Task<IReadOnlyList<samplehostMessage>> MessagesAsync(string apiKey, string conversationId, CancellationToken ct = default) => Task.FromResult(Msgs);
        public Task<samplehostConversationInsight?> ConversationSummaryAsync(string apiKey, string conversationId, CancellationToken ct = default) => Task.FromResult(Summary);
        public Task DeliverAnswerAsync(string apiKey, string conversationId, string toolCallId, string answer, CancellationToken ct = default)
        {
            LastToolAnswer = answer;
            return Task.CompletedTask;
        }
        public Task SendOwnerMessageAsync(string apiKey, string conversationId, string text, CancellationToken ct = default)
        {
            LastOwnerMessage = text;
            return Task.CompletedTask;
        }
        public Task SetMuteAsync(string apiKey, string callControlId, bool muted, CancellationToken ct = default) => Task.CompletedTask;
        public Task SetHoldAsync(string apiKey, string callControlId, bool onHold, CancellationToken ct = default) => Task.CompletedTask;
        public Task HangupAsync(string apiKey, string callControlId, CancellationToken ct = default) => Task.CompletedTask;
        public Task<samplehostCallStatus?> CallStatusAsync(string apiKey, string callControlId, CancellationToken ct = default) => Task.FromResult(Status);
        public Task<IReadOnlyList<PhoneCallEvent>> CallEventsAsync(string apiKey, string callLegId, CancellationToken ct = default) => Task.FromResult<IReadOnlyList<PhoneCallEvent>>([]);
        public Task<samplehostBalance?> BalanceAsync(string apiKey, CancellationToken ct = default) => Task.FromResult<samplehostBalance?>(null);
        public Task<samplehostCallControlApp?> CallControlAppAsync(string apiKey, string connectionId, CancellationToken ct = default) => Task.FromResult<samplehostCallControlApp?>(null);
        public Task<samplehostVoiceProfile?> VoiceProfileAsync(string apiKey, string profileId, CancellationToken ct = default) => Task.FromResult<samplehostVoiceProfile?>(null);
    }
}
