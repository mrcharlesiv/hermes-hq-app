using System.Collections.ObjectModel;
using Hermes.Core.Chat;
using Hermes.Core.Model;
using Hermes.Core.Transcripts;
using Microsoft.UI.Dispatching;

namespace HermesHQ.ViewModels;

/// Mirrors a ChatSession into an ObservableCollection on the UI thread, at most ~30 times a second, touching only
/// the bubbles whose revision changed (spec: "text laid out once and cached").
public sealed partial class ChatViewModel : Observable, IAsyncDisposable
{
    private readonly DispatcherQueue _ui;
    private readonly DispatcherQueueTimer _timer;

    /// Replies whose hidden steps were brought back with Show Steps (or hidden with Hide Steps), kept while open.
    private readonly HashSet<string> _revealed = [];

    public ChatSession Session { get; }
    public ObservableCollection<MessageItem> Items { get; } = [];

    private bool _busy;
    public bool Busy { get => _busy; private set => Set(ref _busy, value); }
    private string? _status;
    public string? Status { get => _status; private set => Set(ref _status, value); }

    public event Action? ItemsChanged;

    /// Measured "Thought for Ns" seconds of a reply by reasoning part index (the activity feature supplies them).
    public static Func<ChatSession, ChatMessage, IReadOnlyDictionary<int, double>?>? ReasoningSeconds { get; set; }
    /// Whether the chat's bot shows its reasoning (`display.show_reasoning`); null = shown.
    public static Func<ChatSession, bool>? ShowReasoning { get; set; }

    public ChatViewModel(ChatSession session, DispatcherQueue ui)
    {
        Session = session;
        _ui = ui;
        _timer = ui.CreateTimer();
        _timer.Interval = TimeSpan.FromMilliseconds(33);
        _timer.IsRepeating = false;
        ObserveChanges();
    }

    /// The bot's name the transcript speaks of ("Hermes couldn't finish this reply").
    public string BotName => Session.Profile is { Length: > 0 } p && p != "default" ? Capitalized(p) : "Hermes";

    private static string Capitalized(string s) => char.ToUpperInvariant(s[0]) + s[1..];

    /// Show Steps / Hide Steps on a reply (After Reply › Hide, the message menu).
    public void ToggleSteps(string messageId)
    {
        if (!_revealed.Remove(messageId)) _revealed.Add(messageId);
        OnChanged();
    }

    public bool Revealed(string messageId) => _revealed.Contains(messageId);

    /// Sends a failed or stopped turn's prompt again (the error card's Try Again).
    public void Retry(string prompt) => _ = Session.SendAsync(prompt);

    private void Apply()
    {
        _dirty = false;
        var fresh = Session.Messages;
        Busy = Session.Busy;
        Status = Session.Status;
        var displays = Displays(fresh);
        var byId = Items.ToDictionary(i => i.Id);
        for (var i = 0; i < fresh.Count; i++)
        {
            var m = fresh[i];
            if (i < Items.Count && Items[i].Id == m.Id) { Items[i].Update(m, displays[i]); continue; }
            if (byId.TryGetValue(m.Id, out var existing))
            {
                var from = Items.IndexOf(existing);
                if (from > i) { Items.Move(from, i); existing.Update(m, displays[i]); continue; }
            }
            Items.Insert(i, new MessageItem(m, this, displays[i]));
        }
        while (Items.Count > fresh.Count) Items.RemoveAt(Items.Count - 1);
        ItemsChanged?.Invoke();
    }

    /// Day lines, times, and each reply's layout inputs (ChatRowBuilder: needsDayBreak, StepRules.isWorking, the
    /// error card's Retry rule, Fewer Timestamps).
    private List<MessageDisplay> Displays(IReadOnlyList<ChatMessage> messages)
    {
        // [WIN-EXTERNAL-SURFACES] Another Hermes process's turn draws as one of ours (its live step line on the last row,
        // no Retry under it), not while a send waits for the owner (ChatViewController's isRunning/externalWorking).
        var turn = ExternalSurfaces.Transcript(Session.Busy, Session.ExternalWorking, Session.WaitingForOwner != null);
        var busy = turn.Running;
        var fewer = ChatDisplaySettings.FewerTimestamps;
        var style = ChatDisplaySettings.Style;
        var hide = ChatDisplaySettings.HidesSteps;
        var showReasoning = ShowReasoning?.Invoke(Session) ?? true;
        var now = DateTimeOffset.Now;
        var lastUser = -1;
        for (var i = messages.Count - 1; i >= 0; i--) if (messages[i].Role == Role.User) { lastUser = i; break; }
        var lastAssistant = -1;
        for (var i = messages.Count - 1; i >= 0; i--) if (messages[i].Role == Role.Assistant) { lastAssistant = i; break; }
        DateTimeOffset? lastTimed = null;
        ChatMessage? prompt = null;
        var o = new List<MessageDisplay>(messages.Count);
        for (var i = 0; i < messages.Count; i++)
        {
            var m = messages[i];
            if (m.Role == Role.User) prompt = m;
            string? day = null;
            if (m.Timestamp is { } t && (m.Parts.Count > 0 || m.Error != null))
            {
                if (DayLines.NeedsBreak(lastTimed, t, fewer)) day = DayLines.Label(t, now);
                lastTimed = t;
            }
            var working = turn.Working(m.IsStreaming, i, messages.Count, lastUser, lastAssistant);
            // Retry: the newest turn, nothing running, its prompt right above it.
            string? retry = null;
            if (!busy && i == messages.Count - 1 && m.Role != Role.User && i > 0 && messages[i - 1].Role == Role.User)
                retry = messages[i - 1].Text;
            var context = new ReplyContext
            {
                Style = style,
                HideSteps = hide,
                Revealed = _revealed.Contains(m.Id),
                ShowReasoning = showReasoning,
                Working = working,
                RunningTail = busy && i == messages.Count - 1,
                // [WIN-OWN-TURN-ROWS] The other process's turn: its live step line on the last row only (`externalTail`).
                ExternalTail = turn.ExternalTail(i, messages.Count),
                TurnSeconds = m.Role == Role.Assistant && prompt != null ? Session.TurnSeconds(prompt) : null,
                ReasoningSeconds = m.Role == Role.Assistant ? ReasoningSeconds?.Invoke(Session, m) : null,
                BotName = BotName,
                CanRetry = retry != null,
            };
            var run = MessageRuns.At(messages, i, fewer, day != null);
            // Only the otherwise quiet, dated run end can need its neighbour's layout. Don't
            // build earlier tool rows on every ordinary streaming or text-only redraw.
            var toolAbove = style == ToolCallStyle.Bubbles && run.JoinedAbove && run.Ends && !run.ShowTime
                && m.Role == Role.Assistant && !m.IsStreaming && m.Timestamp != null
                && EndsInToolBubble(messages[i - 1], o[^1].Context);
            o.Add(new MessageDisplay(day, run, context, retry) { ClockFromToolAbove = toolAbove });
        }
        return o;
    }
    private static bool EndsInToolBubble(ChatMessage m, ReplyContext c) => m.Error == null && !m.Interrupted && m.Tools.Any()
        && ReplyLayout.Build(m, c).LastOrDefault() is ToolBubbleRow
        && (m.IsStreaming || ChangedFiles.Derive(m.Tools).Count == 0);
}
