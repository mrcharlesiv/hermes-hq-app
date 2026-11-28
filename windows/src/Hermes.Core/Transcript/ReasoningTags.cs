using System.Text;
using System.Text.RegularExpressions;

namespace Hermes.Core.Transcripts;

/// Reasoning-tag blocks a model writes into its reply (HermesKit/Chat/Transcript/ReasoningTags.swift):
/// `<think>…</think>` and its kin are hidden wherever a reply is shown or searched (Find), in prose only — a code
/// block's text, fenced or in backticks, stays exactly as written.
public static class ReasoningTags
{
    public const string Names = "think|thinking|reasoning|thought|reasoning_scratchpad|scratchpad|analysis";
    private static readonly Regex OpenTag = new($"<({Names})>", RegexOptions.IgnoreCase);

    /// Nothing would be drawn: only spaces, or only hidden thinking.
    public static bool IsBlank(string text)
    {
        var trimmed = text.Trim();
        if (trimmed.Length == 0) return true;
        return trimmed.Contains('<') && Strip(trimmed).Trim().Length == 0;
    }

    /// The text without its reasoning blocks (see the Swift for the rules: a closed block goes with the spaces and one
    /// line break after it; an unclosed tag hides the rest when it opens the reply, or, while streaming, its line).
    /// Runs in O(N) linear time even on thousands of unclosed `<think>` tags or long lines with backticks (H5).
    public static string Strip(string text, bool streaming = false)
    {
        if (!text.Contains('<')) return text;
        var code = CodeRanges(text);
        var codeIndex = 0;
        var scanPos = 0;
        var ticksOnLine = 0;
        var lineHasNonSpace = false;
        var firstNonSpace = -1;
        HashSet<string>? noClose = null;
        var removals = new List<(int Start, int Length)>();
        var from = 0;

        bool IsInsideFencedCode(int pos)
        {
            while (codeIndex < code.Count && code[codeIndex].Start + code[codeIndex].Length <= pos)
                codeIndex++;
            return codeIndex < code.Count && pos >= code[codeIndex].Start && pos < code[codeIndex].Start + code[codeIndex].Length;
        }

        void AdvanceLineState(int target)
        {
            while (scanPos < target)
            {
                var ch = text[scanPos++];
                if (ch == '\n')
                {
                    ticksOnLine = 0;
                    lineHasNonSpace = false;
                }
                else
                {
                    if (ch == '`') ticksOnLine++;
                    if (ch is not (' ' or '\t')) lineHasNonSpace = true;
                }
            }
        }

        bool HasOnlyWhitespaceBefore(int pos)
        {
            if (firstNonSpace < 0)
            {
                var k = 0;
                while (k < text.Length && char.IsWhiteSpace(text[k])) k++;
                firstNonSpace = k;
            }
            return pos <= firstNonSpace;
        }

        while (from < text.Length)
        {
            var open = OpenTag.Match(text, from);
            if (!open.Success) break;
            AdvanceLineState(open.Index);
            if (IsInsideFencedCode(open.Index) || (ticksOnLine & 1) == 1)
            {
                from = open.Index + open.Length;
                continue;
            }
            var tag = open.Groups[1].Value;
            var afterOpen = open.Index + open.Length;
            var close = noClose is not null && noClose.Contains(tag)
                ? -1
                : text.IndexOf($"</{tag}>", afterOpen, StringComparison.OrdinalIgnoreCase);
            if (close >= 0)
            {
                var end = close + tag.Length + 3;
                while (end < text.Length && text[end] is ' ' or '\t') end++;
                if (end < text.Length && text[end] == '\r' && end + 1 < text.Length && text[end + 1] == '\n') end += 2;
                else if (end < text.Length && text[end] == '\n') end++;
                removals.Add((open.Index, end - open.Index));
                from = end;
                continue;
            }
            (noClose ??= new HashSet<string>(StringComparer.OrdinalIgnoreCase)).Add(tag);
            if (streaming ? !lineHasNonSpace : HasOnlyWhitespaceBefore(open.Index))
            {
                var start = open.Index;
                while (start > 0 && text[start - 1] is ' ' or '\t') start--;
                removals.Add((start, text.Length - start));
                break;
            }
            from = afterOpen;
        }
        if (removals.Count == 0) return text;
        var out_ = new StringBuilder(text.Length);
        var cursor = 0;
        foreach (var (rawStart, length) in removals)
        {
            var start = Math.Max(rawStart, cursor);
            if (start > cursor) out_.Append(text, cursor, start - cursor);
            cursor = Math.Max(cursor, rawStart + length);
        }
        if (cursor < text.Length) out_.Append(text, cursor, text.Length - cursor);
        return out_.ToString();
    }

    /// The fenced code blocks (``` or ~~~, from the fence line to its closing line, or to the end when never closed).
    private static List<(int Start, int Length)> CodeRanges(string s)
    {
        var out_ = new List<(int, int)>();
        if (!s.Contains("```", StringComparison.Ordinal) && !s.Contains("~~~", StringComparison.Ordinal)) return out_;
        string? fence = null;
        var fenceStart = 0;
        var lineStart = 0;
        while (lineStart <= s.Length)
        {
            var newline = s.IndexOf('\n', lineStart);
            var lineEnd = newline < 0 ? s.Length : newline;
            var line = s[lineStart..lineEnd].Trim(' ', '\t', '\r');
            if (fence != null)
            {
                if (line.StartsWith(fence, StringComparison.Ordinal) && line.Trim(fence[0]).Length == 0)
                {
                    out_.Add((fenceStart, lineEnd - fenceStart));
                    fence = null;
                }
            }
            else if (line.StartsWith("```", StringComparison.Ordinal) || line.StartsWith("~~~", StringComparison.Ordinal))
            {
                var count = 0;
                while (count < line.Length && line[count] == line[0]) count++;
                fence = new string(line[0], count);
                fenceStart = lineStart;
            }
            if (newline < 0) break;
            lineStart = lineEnd + 1;
        }
        if (fence != null) out_.Add((fenceStart, s.Length - fenceStart));
        return out_;
    }
}
