using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace Hermes.Core.Voice;

/// What is said aloud (docs/spec/3x-talk.md §3.3, §7; HermesKit/Voice/SpeechText.swift at 93f984bb1): Markdown cleaned
/// for a voice, and sentence cutting for the one-clip voice. The patterns are the Swift's, in the Swift's order.
public static class SpeechText
{
    private static Regex R(string pattern, RegexOptions options = RegexOptions.None) =>
        new(pattern, options | RegexOptions.CultureInvariant);

    private static readonly Regex FencedCode = R(@"```[\s\S]*?(?:```|\z)");
    private static readonly Regex InlineCode = R("`([^`]+)`");
    private static readonly Regex MarkdownLink = R(@"\[([^\]]+)\]\(([^)]+)\)");
    private static readonly Regex ParagraphBreak = R(@"[ \t]*\n{2,}[ \t]*");
    private static readonly Regex PunctuatedParagraphBreak = R(@"([.!?])([*_~`>""'’”)}\]]*)[ \t]*\n{2,}[ \t]*");
    private static readonly Regex SoftBreak = R(@"[ \t]*\n[ \t]*");
    private static readonly Regex MediaPath = R(@"[ \t]*MEDIA:\S+?(?=[.,;:!?)\]]*(?:\s|\z))");
    /// A desktop directive line (`::preview{file="…"}`): a page to look at, not words.
    private static readonly Regex DirectiveLine = R(@"^[ \t]*::[a-z][\w-]*\{[^}\n]*\}[ \t]*\r?$", RegexOptions.Multiline);
    private static readonly Regex LineFinalColon = R(@":\s*$", RegexOptions.Multiline);
    private static readonly Regex ThinkingPrefix = R(
        @"^\s*(?:\([^)\n]{1,48}\)\s*)?(?:processing|thinking|reasoning|analyzing|pondering|contemplating|musing|cogitating|ruminating|deliberating|mulling|reflecting|computing|synthesizing|formulating|brainstorming)\.\.\.\s*",
        RegexOptions.IgnoreCase);
    private static readonly Regex Url = R(@"\bhttps?://\S+", RegexOptions.IgnoreCase);
    private static readonly Regex HyphenBreak = R(@"(\p{L})-\n(\p{L})");
    private static readonly Regex Heading = R(@"^#{1,6}\s+", RegexOptions.Multiline);
    private static readonly Regex Markup = R("[*_~>#]");
    private static readonly Regex Bullet = R(@"^\s*[-+*]\s+", RegexOptions.Multiline);
    private static readonly Regex TrailingColon = R(@":\s*\z");
    private static readonly Regex Whitespace = R(@"\s+");
    /// A full stop left standing alone where a code block was taken out ("Here is the command. . Then…").
    private static readonly Regex OrphanStop = R(@"(?:(?<=[.!?…])\s+|^\s*)\.(?=\s|\z)");
    // Swift's ICU `$` also matches before one final Unicode line break (CR/LF were split already).
    private static readonly Regex TableDelimiter = R(@"\A:?-{3,}:?[\v\f\u0085\u2028\u2029]?\z");
    private static readonly Regex EscapedPipe = R(@"\\\|");
    private static readonly Regex SentenceEnd = R(@"[.!?…。！？]+[""'”’)\]]*\s+");
    private static readonly Regex ClosedCodeBlock = R(@"```[\s\S]*?```");

    public const int MinSentence = 24;

    /// Emoji (U+1F000–1FAFF, U+2600–27BF), variation selector 16, the zero-width joiner and tag characters: each run is
    /// one space (the Swift's `emoji` pattern, written over code points because .NET patterns see UTF-16 units).
    private static bool IsEmoji(int c) =>
        c is >= 0x1F000 and <= 0x1FAFF or >= 0x2600 and <= 0x27BF or 0xFE0F or 0x200D or >= 0xE0020 and <= 0xE007F;

    private static string WithoutEmoji(string text)
    {
        var o = new StringBuilder(text.Length);
        var inRun = false;
        foreach (var rune in text.EnumerateRunes())
        {
            if (IsEmoji(rune.Value))
            {
                if (!inRun) o.Append(' ');
                inRun = true;
                continue;
            }
            inRun = false;
            o.Append(rune.ToString());
        }
        return o.ToString();
    }

    // MARK: Tables: Find reads every cell; only the header row is spoken

    private sealed record TableRow(int Depth, List<string> Cells);

    // Foundation .whitespaces: tab, Unicode space separators, and legacy U+200B. Vertical whitespace is cell data.
    private static string TrimCell(ReadOnlySpan<char> cell)
    {
        static bool Space(char c) => c is '\t' or '\u200B' || char.GetUnicodeCategory(c) == UnicodeCategory.SpaceSeparator;
        int start = 0, end = cell.Length;
        while (start < end && Space(cell[start])) start++;
        while (start < end && Space(cell[end - 1])) end--;
        return cell[start..end].ToString();
    }

    private static bool StartsWithMarker(ReadOnlySpan<char> row, char marker) =>
        !row.IsEmpty && row[0] == marker && StringInfo.GetNextTextElementLength(row) == 1;

    private static TableRow? ParseRow(string line)
    {
        if (!line.Contains('|')) return null;
        var row = line.AsSpan();
        var depth = 0;
        while (true)
        {
            var indent = 0;
            while (StartsWithMarker(row, ' '))
            {
                if (++indent > 3) return null;
                row = row[1..];
            }
            if (StartsWithMarker(row, '\t')) return null;
            if (!StartsWithMarker(row, '>')) break;
            depth++;
            row = row[1..];
            if (StartsWithMarker(row, ' ')) row = row[1..];
        }

        row = row.TrimEnd();
        var cells = new List<string>();
        var start = 0;
        bool leading = false, escaped = false;
        // Swift iterates Characters: a pipe (or a backslash) in a larger grapheme is ordinary cell text.
        for (int i = 0, width; i < row.Length; i += width)
        {
            width = StringInfo.GetNextTextElementLength(row[i..]);
            if (width == 1 && row[i] == '\\') { escaped = !escaped; continue; }
            if (width == 1 && row[i] == '|' && !escaped)
            {
                if (i == 0) leading = true;
                else cells.Add(TrimCell(row[start..i]));
                start = i + 1;
            }
            escaped = false;
        }
        if (start == 0) return null;
        bool trailing = start == row.Length;
        if (!trailing || cells.Count == 0) cells.Add(TrimCell(row[start..]));
        if (cells.Count < 2 && !(leading && trailing)) return null;
        return new TableRow(depth, cells);
    }

    internal static string ReplaceTableEscapes(string cell, string replacement)
    {
        if (!cell.Contains(@"\|", StringComparison.Ordinal)) return cell;
        return EscapedPipe.Replace(cell, m =>
        {
            int pipe = m.Index + 1;
            if (StringInfo.GetNextTextElementLength(cell, pipe) == 1) return replacement;
            // Foundation's substring replacement can't end before a grapheme extender (e.g. | + acute).
            // A spacing mark or ZWJ can share the pipe's grapheme without being an extender. Use the
            // BCL's Unicode data: UAX #29 GB11 joins Pictograph Extend* ZWJ Pictograph into one element.
            var sequence = "\u2764" + Rune.GetRuneAt(cell, pipe + 1) + "\u200D\u2764";
            return StringInfo.GetNextTextElementLength(sequence) == sequence.Length ? m.Value : replacement;
        });
    }

    private static string TableHeader(IReadOnlyList<string> cells)
    {
        var header = string.Join(", ", cells.Select(c => TrimCell(ReplaceTableEscapes(c, " "))).Where(c => c.Length > 0));
        if (header.Length == 0) return header;
        return ".!?:".Contains(header[^1]) ? header : header + ".";
    }

    private static bool IsDelimiter(TableRow row) => row.Cells.All(c => TableDelimiter.IsMatch(c));

    internal enum TableLineKind { Plain, Header, Delimiter, Body }

    /// SpeechText.tables: a header needs a matching delimiter; body rows need only the same quote depth.
    /// Keep each original line too, so Find can leave fenced code alone.
    internal static IEnumerable<(string Raw, TableLineKind Kind, IReadOnlyList<string> Cells)> TableLines(string text)
    {
        var lines = text.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n');
        var index = 0;
        while (index < lines.Length)
        {
            var raw = lines[index++];
            if (index == lines.Length || ParseRow(lines[index]) is not { } delimiter || !IsDelimiter(delimiter)
                || ParseRow(raw) is not { } header || header.Cells.Count != delimiter.Cells.Count || header.Depth != delimiter.Depth)
            {
                yield return (raw, TableLineKind.Plain, []);
                continue;
            }
            yield return (raw, TableLineKind.Header, header.Cells);
            yield return (lines[index++], TableLineKind.Delimiter, delimiter.Cells);
            while (index < lines.Length && ParseRow(lines[index]) is { } body && body.Depth == delimiter.Depth)
                yield return (lines[index++], TableLineKind.Body, body.Cells);
        }
    }

    /// Tables keep only their header row, said as "Item, Value." (a table with an empty header says nothing).
    public static string SummarizeTables(string text)
    {
        var kept = new List<string>();
        foreach (var (raw, kind, cells) in TableLines(text))
        {
            if (kind == TableLineKind.Plain) kept.Add(raw);
            else if (kind == TableLineKind.Header && TableHeader(cells) is { Length: > 0 } header) kept.Add(header);
        }
        return string.Join("\n", kept);
    }

    private static string NormalizeLineBreaks(string text)
    {
        var value = text.Replace("\r\n", "\n").Replace('\r', '\n');
        value = HyphenBreak.Replace(value, "$1$2");
        value = PunctuatedParagraphBreak.Replace(value, "$1$2 ");
        value = ParagraphBreak.Replace(value, ". ");
        return SoftBreak.Replace(value, " ");
    }

    /// The text a voice should say for this Markdown: no code blocks, links read as their words, no addresses, no
    /// emoji, no markup characters. Empty when nothing is speakable.
    public static string SanitizeForSpeech(string text)
    {
        var value = LineFinalColon.Replace(SummarizeTables(DirectiveLine.Replace(text, "")), ".");
        value = NormalizeLineBreaks(value);
        value = FencedCode.Replace(value, "");
        value = ThinkingPrefix.Replace(value, " ");
        value = MarkdownLink.Replace(value, "$1");
        value = InlineCode.Replace(value, "$1");
        value = Url.Replace(value, "");
        value = MediaPath.Replace(value, "");
        value = WithoutEmoji(value);
        value = Heading.Replace(value, "");
        value = Markup.Replace(value, "");
        value = Bullet.Replace(value, "");
        value = TrailingColon.Replace(value, ".");
        value = Whitespace.Replace(value, " ");
        value = OrphanStop.Replace(value, "");
        return value.Trim();
    }

    /// Written text with its finished code blocks taken out; `Held` is a code block that has not closed yet.
    public static (string Text, string Held) WithoutCodeBlocks(string text)
    {
        var closed = ClosedCodeBlock.Replace(text, "\n");
        var open = closed.IndexOf("```", StringComparison.Ordinal);
        return open < 0 ? (closed, "") : (closed[..open], closed[open..]);
    }

    /// Whole sentences of at least `minimum` characters, and what is left. `flush` returns the tail as a sentence too.
    public static SentenceCut CutSentences(string buffer, bool flush, int minimum = MinSentence)
    {
        var sentences = new List<string>();
        var start = 0;
        foreach (Match match in SentenceEnd.Matches(buffer))
        {
            var end = match.Index + match.Length;
            var candidate = buffer[start..end].Trim();
            if (new StringInfo(candidate).LengthInTextElements >= minimum)
            {
                sentences.Add(candidate);
                start = end;
            }
        }
        var rest = buffer[start..];
        if (flush)
        {
            var tail = rest.Trim();
            if (tail.Length > 0) sentences.Add(tail);
            rest = "";
        }
        return new SentenceCut(sentences, rest);
    }
}

/// Whole sentences, and what is left over.
public sealed record SentenceCut(IReadOnlyList<string> Sentences, string Rest);

/// Sentences out of text that arrives a piece at a time (SpeechText.swift SentenceBuffer).
public sealed class SentenceBuffer
{
    private string _buffer = "";

    public IReadOnlyList<string> Append(string delta)
    {
        var cut = SpeechText.CutSentences(_buffer + delta, flush: false);
        _buffer = cut.Rest;
        return cut.Sentences;
    }

    public IReadOnlyList<string> Flush()
    {
        var cut = SpeechText.CutSentences(_buffer, flush: true);
        _buffer = "";
        return cut.Sentences;
    }
}
