using System.Text.RegularExpressions;

namespace Hermes.Core.Transcripts;

/// Reasoning-tag blocks a model writes into its reply (HermesKit/Chat/Transcript/ReasoningTags.swift at 93f984bb1):
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
    public static string Strip(string text, bool streaming = false)
    {
        if (!text.Contains('<')) return text;
        var code = CodeRanges(text);
        var removals = new List<(int Start, int Length)>();
        var from = 0;
        while (from < text.Length)
        {
            var open = OpenTag.Match(text, from);
            if (!open.Success) break;
            if (code.Any(r => open.Index >= r.Start && open.Index < r.Start + r.Length) || InInlineCode(text, open.Index))
            {
                from = open.Index + open.Length;
                continue;
            }
            var tag = open.Groups[1].Value;
            var afterOpen = open.Index + open.Length;
            var close = text.IndexOf($"</{tag}>", afterOpen, StringComparison.OrdinalIgnoreCase);
            if (close >= 0)
            {
                var end = close + tag.Length + 3;
                while (end < text.Length && text[end] is ' ' or '\t') end++;
                if (end < text.Length && text[end] == '\n') end++;
                removals.Add((open.Index, end - open.Index));
                from = end;
                continue;
            }
            if (streaming ? StartsLine(text, open.Index) : text[..open.Index].Trim().Length == 0)
            {
                var start = open.Index;
                while (start > 0 && text[start - 1] is ' ' or '\t') start--;
                removals.Add((start, text.Length - start));
                break;
            }
            from = afterOpen;
        }
        if (removals.Count == 0) return text;
        var out_ = new System.Text.StringBuilder(text);
        for (var i = removals.Count - 1; i >= 0; i--) out_.Remove(removals[i].Start, removals[i].Length);
        return out_.ToString();
    }

    private static bool StartsLine(string s, int index)
    {
        for (var i = index; i > 0; i--)
        {
            var c = s[i - 1];
            if (c == '\n') return true;
            if (c is not (' ' or '\t')) return false;
        }
        return true;
    }

    private static bool InInlineCode(string s, int index)
    {
        var ticks = 0;
        for (var i = index; i > 0; i--)
        {
            var c = s[i - 1];
            if (c == '\n') break;
            if (c == '`') ticks++;
        }
        return ticks % 2 == 1;
    }

    /// The fenced code blocks (``` or ~~~, from the fence line to its closing line, or to the end when never closed).
    private static List<(int Start, int Length)> CodeRanges(string s)
    {
        var out_ = new List<(int, int)>();
        if (!s.Contains("```") && !s.Contains("~~~")) return out_;
        string? fence = null;
        var fenceStart = 0;
        var lineStart = 0;
        while (lineStart <= s.Length)
        {
            var newline = s.IndexOf('\n', lineStart);
            var lineEnd = newline < 0 ? s.Length : newline;
            var line = s[lineStart..lineEnd].Trim(' ', '\t');
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
                fence = new string(line.TakeWhile(c => c == line[0]).ToArray());
                fenceStart = lineStart;
            }
            if (newline < 0) break;
            lineStart = lineEnd + 1;
        }
        if (fence != null) out_.Add((fenceStart, s.Length - fenceStart));
        return out_;
    }
}
