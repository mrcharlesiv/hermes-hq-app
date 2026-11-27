using Hermes.Core.Model;
using Hermes.Core.Settings;

namespace Hermes.Core.Transcripts;

/// App/Chat/ChatRow.swift:1207–1214,1244–1255,1317–1335 (2b547a2b0). Both chat surfaces derive
/// times from the current message list, not from recycled views or from when a row first appeared.
public static class MessageRuns
{
    public static bool Joins(ChatMessage a, ChatMessage b) => a.Role == b.Role && a.Role != Role.System
        && a.Sender?.Key == b.Sender?.Key && a.Reactions is not { Count: > 0 }
        && (a.Timestamp is not { } ta || b.Timestamp is not { } tb || (tb - ta).TotalSeconds <= ChatVisualTokens.RunSeconds);

    public readonly record struct Run(bool JoinedAbove, bool Ends, bool ShowTime);

    public static Run At(IReadOnlyList<ChatMessage> messages, int i, bool fewer, bool dayAbove = false)
    {
        var m = messages[i];
        var joinsAbove = !dayAbove && i > 0 && Joins(messages[i - 1], m);
        var ends = m.Role != Role.System && (i + 1 == messages.Count || !Joins(m, messages[i + 1]));
        var show = ends && !m.IsStreaming && m.Timestamp is { } t && VisibleInMinute(messages, i, fewer, t);
        return new(joinsAbove, ends, show);
    }

    private static bool VisibleInMinute(IReadOnlyList<ChatMessage> messages, int i, bool fewer, DateTimeOffset time)
    {
        var m = messages[i];
        if (!fewer) return true;
        if (m.Role == Role.User) return false;
        if (m.Sender != null) return true;
        // Only a later *own, successful, nonempty reply* in the same clock minute suppresses this one.
        // UTC minute buckets compare instants, including across different stored offsets / a repeated DST hour.
        const int minuteReach = 8;
        for (var j = i + 1; j < messages.Count && j <= i + minuteReach; j++)
        {
            var next = messages[j];
            if (next.Timestamp is not { } t) continue;
            if (t.UtcTicks / TimeSpan.TicksPerMinute != time.UtcTicks / TimeSpan.TicksPerMinute) break;
            // ChatJSON.swift:133 trims Foundation whitespacesAndNewlines, including U+200B.
            if (next.Role == Role.Assistant && next.Sender == null && next.Error == null && !next.Interrupted
                && next.Parts.Any(p => p is TextPart words && words.Text.Any(c => !char.IsWhiteSpace(c) && c != '\u200B'))) return false;
        }
        return true;
    }
}
