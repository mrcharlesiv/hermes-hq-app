using Hermes.Core.Model;

namespace Hermes.Core.Activity;

// Measured reasoning time, "Thought for 7s" (docs/spec/1x-activity.md §9.2). Port of `noteReasoningTimes` and
// `reasoningSeconds` in HermesKit/Activity/LiveChatSession+Activity.swift, and `thoughtTitle` in
// App/Chat/Activity/ActivityRows.swift. Memory only: a reply loaded from history has no times and reads "Thought".
//
// A reasoning part starts when it is first seen with text and ends when a later visible part opens (text, a tool call)
// or the reply stops streaming. Call `Note` once per delivered frame (the Mac does it at most once per display frame)
// after the transcript applied its events (reasoning.delta, message.delta, tool.start, message.complete…).

public sealed class ReasoningClock
{
    private readonly Dictionary<string, Dictionary<int, DateTimeOffset>> _starts = new(StringComparer.Ordinal);
    private readonly Dictionary<string, Dictionary<int, DateTimeOffset>> _ends = new(StringComparer.Ordinal);
    private readonly HashSet<string> _tracked = new(StringComparer.Ordinal);

    /// The clock the timer reads (tests inject one).
    public Func<DateTimeOffset> Clock { get; set; } = () => DateTimeOffset.UtcNow;

    /// Times the parts of the streaming reply `streamingId` (null when none) and of replies still tracked from earlier
    /// frames. `find` returns the message with that id from the transcript, or null once it is gone.
    public void Note(string? streamingId, Func<string, ChatMessage?> find)
    {
        if (streamingId is not null) _tracked.Add(streamingId);
        if (_tracked.Count == 0) return;
        var now = Clock();
        foreach (var id in _tracked.ToList())
        {
            if (find(id) is not { } m) { _tracked.Remove(id); continue; }
            var lastVisible = -1;
            for (var i = m.Parts.Count - 1; i >= 0; i--)
                if (IsVisible(m.Parts[i])) { lastVisible = i; break; }
            for (var i = 0; i < m.Parts.Count; i++)
            {
                if (m.Parts[i] is not ReasoningPart r || r.Text.Trim().Length == 0) continue;
                if (!_starts.TryGetValue(id, out var starts)) _starts[id] = starts = [];
                starts.TryAdd(i, now);
                var open = m.IsStreaming && i >= lastVisible;
                if (open) continue;
                if (!_ends.TryGetValue(id, out var ends)) _ends[id] = ends = [];
                ends.TryAdd(i, now);
            }
            if (!m.IsStreaming) _tracked.Remove(id);
        }
    }

    /// Text and reasoning count once they hold more than whitespace; a tool call (or any other part) always does.
    private static bool IsVisible(ChatPart part) => part switch
    {
        TextPart t => t.Text.Trim().Length > 0,
        ReasoningPart r => r.Text.Trim().Length > 0,
        _ => true,
    };

    /// Measured whole seconds by reasoning part index (rounded down); empty for a reply never seen streaming.
    public IReadOnlyDictionary<int, double> Seconds(string messageId)
    {
        if (!_starts.TryGetValue(messageId, out var starts) || !_ends.TryGetValue(messageId, out var ends))
            return new Dictionary<int, double>();
        var output = new Dictionary<int, double>();
        foreach (var (index, start) in starts)
            if (ends.TryGetValue(index, out var end)) output[index] = Math.Floor(Math.Max(0, (end - start).TotalSeconds));
        return output;
    }

    /// Forget everything (sign-out, chat closed).
    public void Reset()
    {
        _starts.Clear();
        _ends.Clear();
        _tracked.Clear();
    }

    /// "Thinking" while open; "Thought for 7s" / "Thought briefly" when measured; "Thought" from history.
    public static string ThoughtTitle(double? seconds, bool live)
    {
        if (live) return "Thinking";
        if (seconds is not { } s) return "Thought";
        var whole = (int)s;
        return whole == 0 ? "Thought briefly" : $"Thought for {SubagentRules.FormatElapsed(whole)}";
    }
}
