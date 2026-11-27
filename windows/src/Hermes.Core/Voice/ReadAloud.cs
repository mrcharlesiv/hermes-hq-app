using Hermes.Core.Gateways;
using Hermes.Core.Model;

namespace Hermes.Core.Voice;

public enum ReadAloudPhase { Idle, Preparing, Speaking }

/// What the reading is doing (ReadAloudCenter.State): idle, asked for with no audio yet, or speaking one reply.
public sealed record ReadAloudState(ReadAloudPhase Phase, string? MessageId)
{
    public static readonly ReadAloudState Idle = new(ReadAloudPhase.Idle, null);
    public static ReadAloudState Preparing(string id) => new(ReadAloudPhase.Preparing, id);
    public static ReadAloudState Speaking(string id) => new(ReadAloudPhase.Speaking, id);
}

/// What the action row's button shows for one reply (§7.1; ReadAloudCenter.Button).
public enum ReadAloudButton { Idle, Preparing, Speaking }

public static class ReadAloudButtonWords
{
    public static string Label(this ReadAloudButton button) => button switch
    {
        ReadAloudButton.Preparing => "Preparing audio",
        ReadAloudButton.Speaking => "Stop reading",
        _ => "Read Aloud",
    };
}

/// The voice a reading plays through. Windows: the PC's own voices (Windows.Media.SpeechSynthesis), never a network
/// voice. Speaks the sentences in order, calls `started` once when sound begins, and ends when the last has played;
/// cancelling stops it at once. A failure throws `ReadAloudVoiceException` with words for the alert.
public interface IReadAloudVoice
{
    Task SpeakAsync(IReadOnlyList<string> sentences, Action started, CancellationToken cancel);
}

public sealed class ReadAloudVoiceException(string reason) : Exception(reason);

/// Read Aloud and Read Replies Aloud (docs/spec/3x-talk.md §7; App/Chat/Voice/ReadAloudCenter.swift at 93f984bb1): all
/// speech outside a live conversation. One reply at a time; asking for another switches. The Mac speaks through the
/// gateway's voice first and the device's own as the fallback; Windows has the device's own only (the PC's voices).
public sealed class ReadAloudCenter(IReadAloudVoice voice)
{
    public const string FailureTitle = "Couldn’t Read Aloud";
    public const string NothingToRead = "There’s nothing to read in this reply.";
    public static readonly string Unreachable = $"{HostWord.Sentence} isn’t reachable right now. Try again when it reconnects.";
    public const string NoAnswer = "The voice didn’t answer in time. Try again.";
    /// No audio this long after asking: the reading is given up (§7.6). The Mac's `VoiceWire.phoneVoiceAfter + 10`.
    public static readonly TimeSpan DefaultAnswerTimeout = TimeSpan.FromSeconds(20 + 10);

    // What tests swap.
    public IReadAloudVoice Voice { get; set; } = voice;
    public TimeSpan AnswerTimeout { get; set; } = DefaultAnswerTimeout;
    /// The chat's gateway is connected (the Mac's `chat.connection == .ready`).
    public Func<bool> Reachable { get; set; } = () => true;
    /// A reading failed (or there was nothing to read): the chat on screen shows the alert. (scope, reason)
    public Action<string, string>? OnFailure { get; set; }
    /// The state changed (any thread).
    public event Action? Changed;

    /// The reply being read took a new id (Windows: the stored row replaces the live reply when the turn ends), so its
    /// menu still reads Stop Reading. Nothing else changes.
    public void Rebind(string scope, string oldId, string newId)
    {
        bool changed;
        lock (_lock)
        {
            changed = _reading is { } r && r.Scope == scope && r.MessageId == oldId && oldId != newId;
            if (changed) _reading!.MessageId = newId;
        }
        if (changed) Publish();
    }

    private sealed class Reading(string messageId, string scope, bool auto, CancellationTokenSource cancel)
    {
        public string MessageId = messageId;
        public readonly string Scope = scope;
        public readonly bool Auto = auto;
        public readonly CancellationTokenSource Cancel = cancel;
        public bool Audible;
    }

    private readonly object _lock = new();
    private Reading? _reading;
    /// Readings ever started (the walk reads it).
    public int Started { get; private set; }

    public ReadAloudState State
    {
        get
        {
            lock (_lock)
                return _reading is not { } r ? ReadAloudState.Idle
                    : r.Audible ? ReadAloudState.Speaking(r.MessageId) : ReadAloudState.Preparing(r.MessageId);
        }
    }

    /// The chat the reading belongs to.
    public string? Scope { get { lock (_lock) return _reading?.Scope; } }

    public ReadAloudButton ButtonFor(string messageId)
    {
        var state = State;
        if (state.MessageId != messageId) return ReadAloudButton.Idle;
        return state.Phase == ReadAloudPhase.Speaking ? ReadAloudButton.Speaking : ReadAloudButton.Preparing;
    }

    /// The hold menu's tile: Stop Reading while this reply is being read (ChatReadAloudHost.isReading).
    public bool IsReading(string messageId) => State.MessageId == messageId;

    /// The action row and the hold menu: this reply starts, stops, or takes over from another (T30).
    public void Toggle(string messageId, string markdown, string scope)
    {
        if (State.MessageId == messageId) Stop();
        else Read(messageId, markdown, scope, auto: false);
    }

    /// Reads one reply. `auto`: Read Replies Aloud asked (a reply with nothing to say is skipped without an alert).
    public bool Read(string messageId, string markdown, string scope, bool auto)
    {
        var spoken = SpeechText.SanitizeForSpeech(markdown);
        if (spoken.Length == 0)
        {
            if (!auto) OnFailure?.Invoke(scope, NothingToRead);
            return false;
        }
        if (!Reachable())
        {
            if (!auto) OnFailure?.Invoke(scope, Unreachable);
            return false;
        }
        End(announce: false);
        var reading = new Reading(messageId, scope, auto, new CancellationTokenSource());
        lock (_lock)
        {
            _reading = reading;
            Started++;
        }
        var sentences = SpeechText.CutSentences(spoken, flush: true).Sentences;
        _ = Watchdog(reading);
        _ = Run(reading, sentences);
        Publish();
        return true;
    }

    private async Task Run(Reading reading, IReadOnlyList<string> sentences)
    {
        string? failure = null;
        try
        {
            await Voice.SpeakAsync(sentences, () => Began(reading), reading.Cancel.Token);
        }
        catch (OperationCanceledException) { }
        catch (Exception x) { failure = x is ReadAloudVoiceException ? x.Message : $"{x.Message}"; }
        lock (_lock)
        {
            if (_reading != reading) return;
            _reading = null;
        }
        reading.Cancel.Cancel();
        Publish();
        if (failure != null) OnFailure?.Invoke(reading.Scope, failure);
    }

    private void Began(Reading reading)
    {
        lock (_lock)
        {
            if (_reading != reading || reading.Audible) return;
            reading.Audible = true;
        }
        Publish();
    }

    private async Task Watchdog(Reading reading)
    {
        try { await Task.Delay(AnswerTimeout, reading.Cancel.Token); }
        catch (OperationCanceledException) { return; }
        lock (_lock)
            if (_reading != reading || reading.Audible) return;
        End(announce: true);
        OnFailure?.Invoke(reading.Scope, NoAnswer);
    }

    /// [WIN-62] The reading under way is one Read Replies Aloud started (the Mac's speaker owner `.repliesAloud`).
    public bool ReadingReplies { get { lock (_lock) return _reading is { Auto: true }; } }

    /// [WIN-62] Read Replies Aloud turned off: a reply it is reading in `scope` stops; Read Aloud asked for by hand goes on
    /// (ChatReadAloudHost.switchChanged). True when it stopped one.
    public bool StopReplies(string scope)
    {
        lock (_lock)
            if (_reading is not { Auto: true } r || r.Scope != scope) return false;
        End(announce: true);
        return true;
    }

    /// Stop on the strip, the action row, the hold menu; leaving the chat; a new message.
    public void Stop() => End(announce: true);

    /// Stops a reading that belongs to `scope` (its chat left the screen).
    public void Stop(string scope)
    {
        if (Scope == scope) End(announce: true);
    }

    private void End(bool announce)
    {
        Reading? reading;
        lock (_lock)
        {
            reading = _reading;
            _reading = null;
        }
        if (reading == null) return;
        reading.Cancel.Cancel();
        if (announce) Publish();
    }

    private void Publish() => Changed?.Invoke();
}

/// The words of one assistant message, as a voice gets them (LiveChatSession+Talk.swift `spoken`): its text parts in
/// order joined by a blank line (never reasoning, never tools); `Pending` while it streams.
public sealed record SpokenReply(string MessageId, string Text, bool Pending)
{
    public static SpokenReply Of(ChatMessage message) =>
        new(message.Id, string.Join("\n\n", message.Parts.OfType<TextPart>().Select(p => p.Text).Where(t => t.Length > 0)), message.IsStreaming);

    /// The chat's newest reply: its last message, when that is the bot's (`newestReply`).
    public static SpokenReply? Newest(IReadOnlyList<ChatMessage> messages) =>
        messages.Count > 0 && messages[^1].Role == Role.Assistant ? Of(messages[^1]) : null;
}

/// Read Replies Aloud on one chat screen (docs/spec/3x-talk.md §7.4; ChatReadAloudHost.swift at 93f984bb1): a reply that
/// completes while the chat is on screen, after a turn was seen running there, with the switch on, is read; history
/// arriving is never read; while something is being read only the newest reply waits; a send or leaving drops it.
public sealed class ReadRepliesWatch
{
    /// The newest reply already heard, or passed over on purpose: Read Replies Aloud never reads it.
    private string? _heardId;
    /// A turn was seen running while this chat was on screen (history arriving is not a reply completing).
    private bool _sawRunning;
    /// The newest reply that finished while something else was being read: read next.
    private string? _nextId;
    public bool IsOnScreen { get; private set; }

    /// Whether Read Replies Aloud reads a reply that just completed on screen (a paused conversation's notice: no).
    public static bool ReadsCompletedReply(bool switchOn, bool voiceNotice) => switchOn && !voiceNotice;

    public void Appeared(IReadOnlyList<ChatMessage> messages, bool running)
    {
        IsOnScreen = true;
        MarkHeard(messages, running);
        _sawRunning = running;
    }

    public void Left()
    {
        IsOnScreen = false;
        _nextId = null;
    }

    /// The reply that is the latest now will never be read by Read Replies Aloud.
    private void MarkHeard(IReadOnlyList<ChatMessage> messages, bool running)
    {
        if (SpokenReply.Newest(messages) is { Pending: false } reply && !running) _heardId = reply.MessageId;
    }

    /// The chat changed: the reply to read now, if any. `readingHere`: this chat's reading is under way (the reply
    /// waits for it to end).
    public string? SessionChanged(IReadOnlyList<ChatMessage> messages, bool running, bool switchOn, bool readingHere)
    {
        if (!IsOnScreen) return null;
        if (running)
        {
            _sawRunning = true;
            return null;
        }
        if (SpokenReply.Newest(messages) is not { Pending: false } reply || reply.MessageId == _heardId) return null;
        _heardId = reply.MessageId;
        // Only a reply that completed in front of the person, with the switch on.
        if (!_sawRunning || !switchOn) return null;
        _sawRunning = false;
        if (!ReadsCompletedReply(switchOn: true, voiceNotice: false)) return null;
        return Next(reply.MessageId, messages, switchOn, readingHere);
    }

    private string? Next(string messageId, IReadOnlyList<ChatMessage> messages, bool switchOn, bool readingHere)
    {
        if (!IsOnScreen || !switchOn) return null;
        // One at a time: while a reply is read, only the newest waits.
        if (readingHere)
        {
            _nextId = messageId;
            return null;
        }
        return SpokenReply.Newest(messages)?.MessageId == messageId ? messageId : null;
    }

    /// The reading ended: the reply that waited is read if it is still the newest (`inputEnded`).
    public string? ReadingEnded(IReadOnlyList<ChatMessage> messages, bool switchOn)
    {
        if (_nextId is not { } id) return null;
        _nextId = null;
        return Next(id, messages, switchOn, readingHere: false);
    }

    /// A message was sent from this chat: whatever waited is dropped (the reading itself is stopped by the centre).
    public void MessageSent() => _nextId = null;

    /// The switch turned on: the newest reply counts as heard; off: nothing waits.
    public void SwitchChanged(bool on, IReadOnlyList<ChatMessage> messages, bool running)
    {
        if (on) MarkHeard(messages, running);
        else _nextId = null;
    }
}
