using Hermes.Core.Composer;

namespace Hermes.Core.PhoneCalls;

/// Parameters for initiating a phone call.
public sealed record PhoneStartIntent(
    string To,
    string Goal,
    string? TargetName = null,
    PhoneVoicemailChoice Voicemail = PhoneVoicemailChoice.HangUp,
    string? ChatProfile = null,
    string? ChatSessionId = null);

/// Keeps one stable samplehost `Idempotency-Key` across retries of the same dial intent (`PhoneStartRetry`).
public sealed class PhoneStartRetry
{
    private string? _signature;
    private string? _key;

    public string KeyFor(PhoneStartIntent intent)
    {
        var sig = $"{intent.To.Trim()}|{intent.Goal.Trim()}|{intent.Voicemail}";
        if (_signature != sig || _key == null)
        {
            _signature = sig;
            _key = "hermes-call-" + Guid.NewGuid().ToString("N");
        }
        return _key;
    }

    public void Reset()
    {
        _signature = null;
        _key = null;
    }
}

/// Per-account phone call state machine & signaling controller (`App/PhoneCalls/PhoneCallController.swift` port).
public sealed class PhoneCallController
{
    private readonly string _accountId;
    private readonly IsamplehostApi _api;
    private readonly IPhoneKeyStore _keys;
    private readonly IPhoneHistoryStore _historyStore;
    private readonly IKeyValueStore? _setupStore;
    private readonly Func<DateTimeOffset> _clock;
    private readonly PhoneStartRetry _retry = new();

    private readonly List<PhoneCallRecord> _history = [];
    private readonly List<PhoneTranscriptLine> _pendingOwnerLines = [];
    private readonly Dictionary<string, string> _localAnswers = new(StringComparer.Ordinal);
    private PhoneSetup _setup = new();

    public event Action? Changed;

    public PhoneCallController(
        string accountId,
        IsamplehostApi api,
        IPhoneKeyStore keys,
        IPhoneHistoryStore historyStore,
        IKeyValueStore? setupStore = null,
        Func<DateTimeOffset>? clock = null)
    {
        _accountId = accountId;
        _api = api;
        _keys = keys;
        _historyStore = historyStore;
        _setupStore = setupStore;
        _clock = clock ?? (() => DateTimeOffset.UtcNow);

        LoadSetup();
        _history.AddRange(_historyStore.Load(_accountId));
    }

    public string AccountId => _accountId;
    public PhoneSetup Setup => _setup;
    public bool HasApiKey => !string.IsNullOrWhiteSpace(_keys.ReadKey(_accountId));
    public bool IsReady => HasApiKey && _setup.HasRequiredFields;
    public PhoneCallRecord? ActiveCall { get; private set; }
    public IReadOnlyList<PhoneCallRecord> History => _history;

    public void SaveApiKey(string apiKey)
    {
        _keys.SaveKey(_accountId, apiKey);
        Changed?.Invoke();
    }

    public void RemoveApiKey()
    {
        _keys.DeleteKey(_accountId);
        Changed?.Invoke();
    }

    public void SaveSetup(PhoneSetup setup)
    {
        _setup = setup;
        _setupStore?.Set(SetupStorageKey, setup.ToJson().ToJsonString());
        Changed?.Invoke();
    }

    public PhoneCallRecord? FindCall(string callId) =>
        ActiveCall?.Id == callId ? ActiveCall : _history.FirstOrDefault(c => c.Id == callId);

    /// Validates, matches assistant recording preference, and places an outbound call.
    public async Task<PhoneCallRecord> DialAsync(PhoneStartIntent intent, CancellationToken ct = default)
    {
        if (ActiveCall is { IsActive: true })
            throw new InvalidOperationException("Another phone call is already in progress.");

        var apiKey = _keys.ReadKey(_accountId);
        if (string.IsNullOrWhiteSpace(apiKey))
            throw new samplehostException(samplehostErrorKind.NoKey, "Add your samplehost API key in Phone Settings first.");
        if (!_setup.HasRequiredFields)
            throw new InvalidOperationException("Finish Phone Settings (From number, Voice connection, and Assistant) before calling.");

        var to = PhoneFormatting.NormalizeDestination(intent.To)
            ?? throw new ArgumentException("Enter a valid phone number (for example, +15550100123).", nameof(intent));
        var goal = intent.Goal.Trim();
        if (goal.Length == 0)
            throw new ArgumentException("Describe what the call should accomplish.", nameof(intent));
        if (goal.Length > PhoneLimits.MaxGoalChars) goal = goal[..PhoneLimits.MaxGoalChars];

        var targetName = intent.TargetName?.Trim();
        if (targetName is { Length: > PhoneLimits.MaxNameChars }) targetName = targetName[..PhoneLimits.MaxNameChars];

        _pendingOwnerLines.Clear();
        _localAnswers.Clear();

        var call = new PhoneCallRecord
        {
            Id = Guid.NewGuid().ToString("N")[..12],
            AccountId = _accountId,
            To = to,
            TargetName = string.IsNullOrEmpty(targetName) ? null : targetName,
            Goal = goal,
            Voicemail = intent.Voicemail,
            State = PhoneCallState.Dialing,
            StartedAt = _clock(),
            ChatProfile = intent.ChatProfile,
            ChatSessionId = intent.ChatSessionId,
        };
        ActiveCall = call;
        Changed?.Invoke();

        try
        {
            // Match assistant recording setting before dialing (`PhoneCallController.swift` invariant).
            await _api.MatchRecordingAsync(apiKey, _setup.AssistantId!, _setup.RecordCalls, ct);

            var req = new PhoneDialRequest(
                To: to,
                From: _setup.FromNumber!,
                ConnectionId: _setup.ConnectionId!,
                AssistantId: _setup.AssistantId!,
                Goal: goal,
                TargetName: call.TargetName,
                Voicemail: intent.Voicemail,
                OwnerName: _setup.OwnerName,
                Record: _setup.RecordCalls,
                IdempotencyKey: _retry.KeyFor(intent));

            var dialed = await _api.DialAsync(apiKey, req, ct);
            _retry.Reset();
            ActiveCall = call with
            {
                State = PhoneCallState.Ringing,
                CallControlId = dialed.CallControlId,
                CallLegId = dialed.CallLegId,
            };
            Changed?.Invoke();
            return ActiveCall;
        }
        catch (Exception ex)
        {
            var reason = PhoneMessages.Format(ex, apiKey);
            ActiveCall = FinalizeCall(call, PhoneOutcome.CouldNotConnect(reason), PhoneLocalEnd.None, error: reason);
            throw;
        }
    }

    /// Polls samplehost call status, events, conversation transcript, and enforces ring/safety timeouts.
    public async Task<PhoneCallRecord?> RefreshActiveAsync(CancellationToken ct = default)
    {
        if (ActiveCall is not { IsActive: true } call) return ActiveCall;
        var apiKey = _keys.ReadKey(_accountId);
        if (string.IsNullOrWhiteSpace(apiKey) || string.IsNullOrWhiteSpace(call.CallControlId)) return call;

        var now = _clock();
        var status = await _api.CallStatusAsync(apiKey, call.CallControlId, ct);
        var events = !string.IsNullOrWhiteSpace(call.CallLegId)
            ? await _api.CallEventsAsync(apiKey, call.CallLegId, ct)
            : [];

        var convId = call.ConversationId ?? await _api.ConversationIdAsync(apiKey, call.CallControlId, ct);
        var lines = call.Lines;
        var pendingQ = call.PendingQuestion;
        var qas = call.QAs;

        if (!string.IsNullOrWhiteSpace(convId))
        {
            var msgs = await _api.MessagesAsync(apiKey, convId, ct);
            var snap = PhoneTranscript.Read(msgs, _pendingOwnerLines, _localAnswers);
            lines = snap.Lines;
            pendingQ = snap.PendingQuestion;
            qas = snap.QAs;
        }

        var answeredAt = call.AnsweredAt ?? status?.AnsweredAt
            ?? (status?.State is "active" or "answered" or "connected" ? now : (DateTimeOffset?)null)
            ?? (lines.Count > 0 ? now : (DateTimeOffset?)null);
        var voicemailDetected = call.VoicemailDetected
            || events.Any(e => e.MachineResult?.Contains("machine", StringComparison.OrdinalIgnoreCase) == true);

        // Enforce 30-minute safety stop when live.
        if (answeredAt != null && (now - answeredAt.Value).TotalSeconds >= PhoneLimits.MaxCallSeconds)
        {
            ActiveCall = call with { ConversationId = convId, AnsweredAt = answeredAt, Lines = lines, PendingQuestion = pendingQ, QAs = qas };
            return await HangupAsync(PhoneLocalEnd.SafetyStop, ct);
        }

        // Enforce 45-second ring timeout when still ringing unanswered.
        if (answeredAt == null && (now - call.StartedAt).TotalSeconds >= PhoneLimits.RingTimeoutSeconds)
        {
            ActiveCall = call with { ConversationId = convId, Lines = lines, PendingQuestion = pendingQ, QAs = qas };
            return await HangupAsync(PhoneLocalEnd.RingTimeout, ct);
        }

        if (status is { IsAlive: false } || call.State == PhoneCallState.Ending)
        {
            var outcome = PhoneVerdict.Derive(events, status, call.LocalEnd, lines, answeredAt != null);
            string? summary = call.Summary;
            if (!string.IsNullOrWhiteSpace(convId))
            {
                try { summary = (await _api.ConversationSummaryAsync(apiKey, convId, ct))?.Summary ?? summary; }
                catch (Exception) { /* summary insight is optional */ }
            }
            var updated = call with
            {
                ConversationId = convId,
                AnsweredAt = answeredAt,
                Lines = lines,
                PendingQuestion = null,
                QAs = qas,
                Summary = summary,
                VoicemailDetected = voicemailDetected || outcome.Kind == PhoneOutcomeKind.Voicemail,
            };
            ActiveCall = FinalizeCall(updated, outcome, call.LocalEnd);
            return ActiveCall;
        }

        var nextState = call.State == PhoneCallState.OnHold
            ? PhoneCallState.OnHold
            : answeredAt != null
                ? PhoneCallState.Connected
                : PhoneCallState.Ringing;

        ActiveCall = call with
        {
            State = nextState,
            ConversationId = convId,
            AnsweredAt = answeredAt,
            Lines = lines,
            PendingQuestion = pendingQ,
            QAs = qas,
            VoicemailDetected = voicemailDetected,
        };
        Changed?.Invoke();
        return ActiveCall;
    }

    public async Task AnswerQuestionAsync(string toolCallId, string answer, CancellationToken ct = default)
    {
        var clean = answer.Trim();
        if (clean.Length == 0 || ActiveCall is not { IsActive: true } call) return;
        var apiKey = _keys.ReadKey(_accountId);
        if (string.IsNullOrWhiteSpace(apiKey) || string.IsNullOrWhiteSpace(call.ConversationId)) return;

        _localAnswers[toolCallId] = clean;
        var pendingLine = new PhoneTranscriptLine("you-" + Guid.NewGuid().ToString("N")[..8], PhoneSpeaker.You, clean, _clock(), Pending: true);
        _pendingOwnerLines.Add(pendingLine);
        var updatedQas = call.PendingQuestion?.ToolCallId == toolCallId
            ? call.QAs.Append(new PhoneQA(call.PendingQuestion.Question, clean)).ToList()
            : call.QAs;
        ActiveCall = call with
        {
            PendingQuestion = call.PendingQuestion?.ToolCallId == toolCallId ? null : call.PendingQuestion,
            QAs = updatedQas,
            Lines = [.. call.Lines, pendingLine],
        };
        Changed?.Invoke();

        await _api.DeliverAnswerAsync(apiKey, call.ConversationId, toolCallId, clean, ct);
    }

    public async Task TellAssistantAsync(string instruction, CancellationToken ct = default)
    {
        var clean = instruction.Trim();
        if (clean.Length == 0 || ActiveCall is not { IsActive: true } call) return;
        var apiKey = _keys.ReadKey(_accountId);
        if (string.IsNullOrWhiteSpace(apiKey) || string.IsNullOrWhiteSpace(call.ConversationId)) return;

        var pendingLine = new PhoneTranscriptLine("you-" + Guid.NewGuid().ToString("N")[..8], PhoneSpeaker.You, clean, _clock(), Pending: true);
        _pendingOwnerLines.Add(pendingLine);
        ActiveCall = call with { Lines = [.. call.Lines, pendingLine] };
        Changed?.Invoke();

        await _api.SendOwnerMessageAsync(apiKey, call.ConversationId, clean, ct);
    }

    public async Task ToggleMuteAsync(CancellationToken ct = default)
    {
        if (ActiveCall is not { IsLive: true } call || string.IsNullOrWhiteSpace(call.CallControlId)) return;
        var apiKey = _keys.ReadKey(_accountId);
        if (string.IsNullOrWhiteSpace(apiKey)) return;

        var nextMuted = !call.IsMuted;
        await _api.SetMuteAsync(apiKey, call.CallControlId, nextMuted, ct);
        ActiveCall = call with { IsMuted = nextMuted };
        Changed?.Invoke();
    }

    public async Task ToggleHoldAsync(CancellationToken ct = default)
    {
        if (ActiveCall is not { IsLive: true } call || string.IsNullOrWhiteSpace(call.CallControlId)) return;
        var apiKey = _keys.ReadKey(_accountId);
        if (string.IsNullOrWhiteSpace(apiKey)) return;

        var nextHold = !call.IsOnHold;
        await _api.SetHoldAsync(apiKey, call.CallControlId, nextHold, ct);
        ActiveCall = call with { State = nextHold ? PhoneCallState.OnHold : PhoneCallState.Connected };
        Changed?.Invoke();
    }

    public async Task<PhoneCallRecord?> HangupAsync(PhoneLocalEnd localEnd = PhoneLocalEnd.YouHungUp, CancellationToken ct = default)
    {
        if (ActiveCall is not { IsActive: true } call) return ActiveCall;
        ActiveCall = call with { State = PhoneCallState.Ending, LocalEnd = localEnd };
        Changed?.Invoke();

        var apiKey = _keys.ReadKey(_accountId);
        if (!string.IsNullOrWhiteSpace(apiKey) && !string.IsNullOrWhiteSpace(call.CallControlId))
        {
            try { await _api.HangupAsync(apiKey, call.CallControlId, ct); }
            catch (Exception) { /* hangup best-effort if remote already disconnected */ }
        }

        var outcome = localEnd == PhoneLocalEnd.RingTimeout && call.AnsweredAt == null
            ? PhoneOutcome.NoAnswer
            : call.VoicemailDetected
                ? PhoneOutcome.Voicemail
                : PhoneOutcome.Finished;
        ActiveCall = FinalizeCall(ActiveCall, outcome, localEnd);
        return ActiveCall;
    }

    /// Delivers finished call summary results to their originating chats when `SendResultsToChat` is enabled.
    public async Task<int> DeliverPendingResultsAsync(Func<string, string, string, Task<bool>> sendToChat, CancellationToken ct = default)
    {
        var delivered = 0;
        var apiKey = _keys.ReadKey(_accountId);
        for (var i = 0; i < _history.Count; i++)
        {
            ct.ThrowIfCancellationRequested();
            var call = _history[i];
            if (call.ResultDelivery != PhoneResultDeliveryState.Pending) continue;
            if (string.IsNullOrWhiteSpace(call.ChatProfile) || string.IsNullOrWhiteSpace(call.ChatSessionId))
            {
                _history[i] = call with { ResultDelivery = PhoneResultDeliveryState.Skipped };
                continue;
            }
            var body = PhoneResultMessage.Format(call, apiKey);
            if (await sendToChat(call.ChatProfile!, call.ChatSessionId!, body))
            {
                _history[i] = call with { ResultDelivery = PhoneResultDeliveryState.Delivered };
                delivered++;
            }
        }
        if (delivered > 0)
        {
            _historyStore.Save(_accountId, _history);
            Changed?.Invoke();
        }
        return delivered;
    }

    public bool DeleteCall(string callId)
    {
        var removed = _history.RemoveAll(c => c.Id == callId) > 0;
        if (removed)
        {
            _historyStore.Save(_accountId, _history);
            Changed?.Invoke();
        }
        return removed;
    }

    public void ClearHistory()
    {
        _history.Clear();
        _historyStore.Clear(_accountId);
        Changed?.Invoke();
    }

    public async Task EndAllAsync()
    {
        if (ActiveCall is { IsActive: true })
            await HangupAsync(PhoneLocalEnd.YouHungUp);
    }

    private PhoneCallRecord FinalizeCall(PhoneCallRecord call, PhoneOutcome outcome, PhoneLocalEnd localEnd, string? error = null)
    {
        var shouldDeliver = _setup.SendResultsToChat
            && !string.IsNullOrWhiteSpace(call.ChatProfile)
            && !string.IsNullOrWhiteSpace(call.ChatSessionId);

        var finalized = call with
        {
            State = PhoneCallState.Ended,
            EndedAt = call.EndedAt ?? _clock(),
            Outcome = outcome,
            LocalEnd = localEnd,
            PendingQuestion = null,
            Error = error ?? call.Error,
            ResultDelivery = shouldDeliver ? PhoneResultDeliveryState.Pending : PhoneResultDeliveryState.Skipped,
        };

        _history.RemoveAll(c => c.Id == finalized.Id);
        _history.Insert(0, finalized);
        if (_history.Count > PhoneLimits.MaxHistoryCalls)
            _history.RemoveRange(PhoneLimits.MaxHistoryCalls, _history.Count - PhoneLimits.MaxHistoryCalls);
        _historyStore.Save(_accountId, _history);
        _pendingOwnerLines.Clear();
        _localAnswers.Clear();
        Changed?.Invoke();
        return finalized;
    }

    private string SetupStorageKey => "phone.setup." + _accountId;

    private void LoadSetup()
    {
        if (_setupStore?.Get(SetupStorageKey) is { Length: > 0 } raw && J.Parse(raw) is { } node)
            _setup = PhoneSetup.FromJson(node);
    }
}
