using System.Globalization;
using System.Text.RegularExpressions;
using Hermes.Core.Model;
using Hermes.Core.Voice;

namespace Hermes.Core.Transcripts;

// Find in a chat (HermesKit/Chat/ChatFind.swift and App/Chat/Find/ChatFindController.swift at 93f984bb1; parity 240 §5):
// the words on screen, counted and stepped through. Only text that is drawn is searched: your messages and the bot's
// prose, one unit per bubble, oldest first, case- and diacritic-insensitively. Not tool steps, thinking, notices or
// slash output.

/// One bubble's searchable text: the bubble's row id ("<message id>|b<part>") and its words as they read on screen.
public sealed record ChatFindUnit(string RowId, string MessageId, string Text);

/// A match: the bubble it sits in and which occurrence of the query it is there (0-based, in reading order).
public sealed record ChatFindMatch(string RowId, string MessageId, int Occurrence);

/// One occurrence in a text, as UTF-16 offsets (what a TextHighlighter takes).
public readonly record struct ChatFindRange(int Start, int Length);

/// What a message draws for Find: every occurrence of `Query`, the `Current`-th (counted across the message) in the
/// current colour; null Current: none of this message's is current.
public sealed record ChatFindHighlight(string Query, int? Current);

/// The bar's words (ChatFindBar in ChatFindController.swift).
public static class ChatFindWords
{
    public const string Placeholder = "Find in Chat";
    public const string Previous = "Previous Match";
    public const string Next = "Next Match";
    public const string Done = "Done";
    public const string Earlier = "Search Earlier Messages";
    public const string EarlierLoading = "Loading Earlier Messages…";
}

public static class ChatFind
{
    private static readonly CompareInfo Compare = CultureInfo.InvariantCulture.CompareInfo;
    /// `[.caseInsensitive, .diacriticInsensitive]`.
    private const CompareOptions Options = CompareOptions.IgnoreCase | CompareOptions.IgnoreNonSpace;

    /// The bubbles the transcript draws for these messages, oldest first, with the text each shows (ChatFind.units):
    /// your message is "b0" (a voice memo: anything typed with it, "b1"); each non-empty text part of a reply is
    /// "b<part index>". System rows (notices, slash output) are not searched. (Windows' ChatMessage carries no other-bot
    /// sender yet, so the Mac's "another bot's delivery" exclusion has nothing to test here.)
    public static IReadOnlyList<ChatFindUnit> Units(IEnumerable<ChatMessage> messages)
    {
        var out_ = new List<ChatFindUnit>();
        foreach (var m in messages)
        {
            switch (m.Role)
            {
                case Role.System:
                    continue;
                case Role.User:
                    var text = string.Join("\n", m.Parts.OfType<TextPart>().Select(p => p.Text));
                    if (VoiceMemoRest(text) is { } rest)
                    {
                        // The memo's own bubble is an audio message (its transcript folds away): only what was typed with it.
                        if (rest.Length > 0) out_.Add(new ChatFindUnit($"{m.Id}|b1", m.Id, rest));
                    }
                    else if (text.Trim().Length > 0) out_.Add(new ChatFindUnit($"{m.Id}|b0", m.Id, text));
                    break;
                case Role.Assistant:
                    for (var i = 0; i < m.Parts.Count; i++)
                    {
                        if (m.Parts[i] is not TextPart t || ReasoningTags.IsBlank(t.Text)) continue;
                        out_.Add(new ChatFindUnit($"{m.Id}|b{i}", m.Id, DrawnText(t.Text)));
                    }
                    break;
            }
        }
        return out_;
    }

    private static readonly Regex MediaToken = new("""[`"']?MEDIA:\s*(?:`[^`\n]+`|"[^"\n]+"|'[^'\n]+'|[^\s`"]+)[`"']?""", RegexOptions.IgnoreCase);

    /// A reply part's words as its bubble draws them: no hidden thinking, a link's words without its address, and no
    /// `MEDIA:` line (its picture or file row is drawn instead of the words).
    public static string DrawnText(string markdown)
    {
        var text = ReasoningTags.Strip(markdown);
        if (text.Contains("MEDIA:", StringComparison.Ordinal))
        {
            // MediaTags.renderTags: a line that is only its tags is dropped; otherwise the tag goes and the words stay.
            var kept = new List<string>();
            foreach (var line in text.Split('\n'))
            {
                if (!line.Contains("MEDIA:", StringComparison.Ordinal)) { kept.Add(line); continue; }
                var words = MediaToken.Replace(line, "").Trim();
                if (words.Length > 0) kept.Add(words);
            }
            text = string.Join("\n", kept);
        }
        return ReadableText(text);
    }

    private static readonly Regex Fence = new(@"^\s*(```|~~~)");
    private static readonly Regex ListMarker = new(@"^(\s*)[-*+]\s+(\[[ xX]\]\s+)?");
    private static readonly Regex Heading = new(@"^\s*#{1,6}\s+");
    private static readonly Regex Quote = new(@"^\s*>\s?");
    private static readonly Regex Image = new(@"!\[([^\]]*)\]\([^)]*\)");
    private static readonly Regex Link = new(@"\[([^\]]+)\]\(([^)\s]+)[^)]*\)");
    private static readonly Regex Strong = new(@"(\*\*|__)(?=\S)(.+?)(?<=\S)\1");
    private static readonly Regex StarEm = new(@"(?<![\w*])\*(?=\S)([^*\n]+?)(?<=\S)\*(?![\w*])");
    private static readonly Regex UnderscoreEm = new(@"(?<![\w])_(?=\S)([^_\n]+?)(?<=\S)_(?![\w])");
    private static readonly Regex Strike = new(@"~~(?=\S)(.+?)(?<=\S)~~");
    private static readonly Regex InlineCode = new(@"`([^`\n]+)`");

    /// ChatTranscript.readableText(_, linkAddresses: false): no `**`, `_` or backtick markers, "•" bullets, a heading's
    /// words, a link's words alone, table cells separated by tabs; code blocks keep their text, only the fences go.
    public static string ReadableText(string markdown)
    {
        var fenced = false;
        var out_ = new List<string>();
        foreach (var (raw, kind, cells) in SpeechText.TableLines(markdown))
        {
            if (Fence.IsMatch(raw)) { fenced = !fenced; continue; }
            if (fenced) { out_.Add(raw); continue; }
            if (kind == SpeechText.TableLineKind.Delimiter) continue;
            var line = kind == SpeechText.TableLineKind.Plain ? raw
                : string.Join("\t", cells.Select(c => SpeechText.ReplaceTableEscapes(c, "|")));
            line = ListMarker.Replace(line, "$1• ");
            line = Heading.Replace(line, "");
            line = Quote.Replace(line, "");
            line = Image.Replace(line, "$1");
            line = Link.Replace(line, "$1");
            line = Strong.Replace(line, "$2");
            line = StarEm.Replace(line, "$1");
            line = UnderscoreEm.Replace(line, "$1");
            line = Strike.Replace(line, "$1");
            line = InlineCode.Replace(line, "$1");
            out_.Add(line);
        }
        return string.Join("\n", out_);
    }

    /// The query as searched: as typed, minus leading and trailing spaces ("" finds nothing).
    public static string Normalized(string query) => query.Trim();

    /// Every occurrence of `query` in `text`, in order, never overlapping.
    public static IReadOnlyList<ChatFindRange> Ranges(string query, string text)
    {
        query = Normalized(query);
        if (query.Length == 0 || text.Length == 0) return [];
        // An unrelated zero-weight query keeps its existing collation behaviour, even if this bubble has an emoji.
        if (ChatFindEmojiModifiers.ContainsTone(query) ||
            (ChatFindEmojiModifiers.ContainsTone(text) && Compare.Compare(query, "", Options) != 0))
            return ChatFindEmojiModifiers.Ranges(query, text, Compare, Options);

        var out_ = new List<ChatFindRange>();
        var from = 0;
        while (from < text.Length)
        {
            var at = Compare.IndexOf(text.AsSpan(from), query.AsSpan(), Options, out var length);
            if (at < 0) break;
            out_.Add(new ChatFindRange(from + at, length));
            from = from + at + Math.Max(1, length);
        }
        return out_;
    }

    /// Every match in the messages, oldest first.
    public static IReadOnlyList<ChatFindMatch> Matches(string query, IEnumerable<ChatMessage> messages) =>
        Matches(query, Units(messages));

    public static IReadOnlyList<ChatFindMatch> Matches(string query, IReadOnlyList<ChatFindUnit> units)
    {
        var out_ = new List<ChatFindMatch>();
        if (Normalized(query).Length == 0) return out_;
        foreach (var unit in units)
        {
            var count = Ranges(query, unit.Text).Count;
            for (var k = 0; k < count; k++) out_.Add(new ChatFindMatch(unit.RowId, unit.MessageId, k));
        }
        return out_;
    }

    /// Where a match is drawn (ChatFind.drawnPlace): parts with nothing drawn between them are one bubble under the
    /// first one's id (`bubbleParts`: the part indices the reply's bubbles start at, null while unbuilt).
    public static (string RowId, int Occurrence) DrawnPlace(ChatFindMatch match, IReadOnlyList<int>? bubbleParts,
        IReadOnlyList<ChatFindUnit> units, string query)
    {
        var prefix = $"{match.MessageId}|b";
        if (!match.RowId.StartsWith(prefix, StringComparison.Ordinal) || !int.TryParse(match.RowId[prefix.Length..], out var part)
            || bubbleParts?.LastOrDefault(p => p <= part, -1) is not { } start || start < 0 || start >= part)
            return (match.RowId, match.Occurrence);
        var before = 0;
        foreach (var unit in units)
        {
            if (unit.MessageId != match.MessageId || !unit.RowId.StartsWith(prefix, StringComparison.Ordinal)) continue;
            if (!int.TryParse(unit.RowId[prefix.Length..], out var p) || p < start || p >= part) continue;
            before += Ranges(query, unit.Text).Count;
        }
        return ($"{prefix}{start}", before + match.Occurrence);
    }

    /// Windows draws one view per message: the match's occurrence counted across all of its message's units.
    public static int MessageOccurrence(ChatFindMatch match, IReadOnlyList<ChatFindUnit> units, string query)
    {
        var before = 0;
        foreach (var unit in units)
        {
            if (unit.MessageId != match.MessageId) continue;
            if (unit.RowId == match.RowId) break;
            before += Ranges(query, unit.Text).Count;
        }
        return before + match.Occurrence;
    }

    /// "2 of 5" (the current match's 1-based place), "No Results" for none, "" before anything is typed. While earlier
    /// messages aren't loaded (`hasOlder`) none found reads "No Results Yet".
    public static string CountText(int? current, int total, string query, bool hasOlder = false)
    {
        if (Normalized(query).Length == 0) return "";
        if (total <= 0) return hasOlder ? "No Results Yet" : "No Results";
        return $"{(current ?? 0) + 1} of {total}";
    }

    /// The match to show after the matches changed: the same one when it is still there, otherwise the newest.
    public static int? KeepCurrent(ChatFindMatch? previous, IReadOnlyList<ChatFindMatch> matches)
    {
        if (matches.Count == 0) return null;
        if (previous != null)
            for (var i = 0; i < matches.Count; i++) if (matches[i] == previous) return i;
        return matches.Count - 1;
    }

    /// Steps forward (newer, ↓) or back (older, ↑), wrapping around.
    public static int? Step(int? current, int count, bool forward)
    {
        if (count <= 0) return null;
        if (current is not { } c) return forward ? 0 : count - 1;
        return forward ? (c + 1) % count : (c - 1 + count) % count;
    }

    /// VoiceMemo.parse(text)?.rest (HermesKit/Voice/MemoText.swift; Hermes.Core.Voice.VoiceMemo): a user turn opening
    /// with `MEDIA:"<audio path>"` is a memo; what was typed after its transcript line is the rest. Null: not a memo.
    public static string? VoiceMemoRest(string text) => VoiceMemo.Parse(text)?.Rest;
}

/// The Find bar's state (ChatFindController): the query, the matches oldest first, the current one, and whether the
/// bar is open. The page feeds it the messages; it never logs the query.
public sealed class ChatFindModel
{
    private IReadOnlyList<ChatFindUnit> _units = [];
    public string Query { get; private set; } = "";
    public IReadOnlyList<ChatFindMatch> Matches { get; private set; } = [];
    public int? Current { get; private set; }
    public bool IsActive { get; private set; }
    public bool HasOlder { get; private set; }

    public void Open() => IsActive = true;

    /// Done, Esc: the words, the matches and the current one go.
    public void Close()
    {
        IsActive = false;
        Query = "";
        Matches = [];
        Current = null;
        _units = [];
    }

    /// Searches `messages` for `query`. `keepCurrent`: the transcript changed (the current match stays when it is still
    /// there); false: the query was typed (the newest match). Returns whether the view should move to the current match
    /// (as the Mac's reveal: a new query, or no previous match to keep).
    public bool Search(string query, IEnumerable<ChatMessage> messages, bool keepCurrent, bool hasOlder = false)
    {
        Query = query;
        HasOlder = hasOlder;
        _units = ChatFind.Units(messages);
        var previous = Current is { } c && c < Matches.Count ? Matches[c] : null;
        Matches = ChatFind.Matches(query, _units);
        Current = ChatFind.KeepCurrent(keepCurrent ? previous : null, Matches);
        return !keepCurrent || previous == null;
    }

    /// Edit › Find Next / Find Previous have something to step to.
    public bool CanStep => IsActive && Matches.Count > 0;

    public void Step(bool forward)
    {
        if (Matches.Count == 0) return;
        Current = ChatFind.Step(Current, Matches.Count, forward);
    }

    public ChatFindMatch? CurrentMatch => Current is { } c && c < Matches.Count ? Matches[c] : null;

    public string CountText => ChatFind.CountText(Current, Matches.Count, Query, HasOlder);

    /// What message `messageId` highlights: null when nothing is found (or Find is closed).
    public ChatFindHighlight? Highlight(string messageId)
    {
        if (!IsActive || ChatFind.Normalized(Query).Length == 0 || Matches.Count == 0) return null;
        var current = CurrentMatch is { } m && m.MessageId == messageId ? ChatFind.MessageOccurrence(m, _units, Query) : (int?)null;
        return new ChatFindHighlight(Query, current);
    }
}
