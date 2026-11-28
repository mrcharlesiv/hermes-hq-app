namespace Hermes.Core.Transcripts;

// Port of App/Chat/Render/MarkdownComplexity.swift (spec 03 §9.3, H5): linear-time pre-parse guard that detects
// pathological markdown shapes (deeply nested quotes/lists, excessive list indentation, huge runs of emphasis
// delimiters or brackets, very long single-character runs, or oversized replies) so the renderer falls back cleanly
// to plain text before invoking Markdig.
public static class MarkdownComplexity
{
    /// Container markers ('- ', '> ', '1. ') opening one line.
    public const int MaxNesting = 32;
    /// Leading spaces before a list marker.
    public const int MaxListIndent = 128;
    /// Emphasis delimiters that can open ('*' before a non-space, '_' starting a word) in one paragraph.
    public const int MaxDelimiters = 500;
    /// '[' or '<' in one paragraph.
    public const int MaxBrackets = 1000;
    /// One character repeated: '*'/'_' runs outside fences, and any space/tab/backtick/tilde/'*'/'_' run.
    public const int MaxDelimiterRun = 256;
    public const int MaxRun = 1000;
    /// Replies above this length render directly as plain text without running math extraction or Markdown parsing.
    public const int PlainTextLimit = 200_000;

    public enum Verdict
    {
        /// Safe to parse normally.
        Simple,
        /// Within the limits but deeply nested enough to note.
        Deep,
        /// Past a limit: draw as plain text.
        TooComplex,
    }

    private const int DeepNesting = 12;
    private const int DeepRun = 24;
    private const int DeepDelimiters = 64;

    public static bool ExceedsPlainTextLimit(string text) => text.Length > PlainTextLimit;

    public static bool IsTooComplex(string text) => Evaluate(text) == Verdict.TooComplex;

    /// True when the reply should skip Markdown parsing and render as plain text.
    public static bool ShouldRenderPlainText(string text) => ExceedsPlainTextLimit(text) || IsTooComplex(text);

    public static Verdict Evaluate(string text) => Scan(text.AsSpan());

    private static Verdict Scan(ReadOnlySpan<char> b)
    {
        var n = b.Length;
        static int At(ReadOnlySpan<char> span, int i) => i >= 0 && i < span.Length ? span[i] : -1;
        static bool Space(int c) => c is ' ' or '\t';
        static bool Word(int c) => c is (>= '0' and <= '9') or (>= 'A' and <= 'Z') or (>= 'a' and <= 'z') or > 127;

        (int A, int B, int C)? fence = null;
        var delimiters = 0;
        var brackets = 0;
        var deep = false;
        var start = 0;
        while (start <= n)
        {
            var end = start;
            while (end < n && b[end] != '\n') end++;
            var lineEnd = end > start && b[end - 1] == '\r' ? end - 1 : end;

            // Leading indentation, then container markers.
            var cursorAt = start;
            var indent = 0;
            while (cursorAt < lineEnd && Space(b[cursorAt]))
            {
                indent += b[cursorAt] == '\t' ? 4 : 1;
                cursorAt++;
            }

            // The next three characters (a newline or end-of-text among them never matches a fence).
            var opener = (At(b, cursorAt), At(b, cursorAt + 1), At(b, cursorAt + 2));
            var isFence = opener is ('`', '`', '`') or ('~', '~', '~');
            if (fence is { } f)
            {
                if (opener == f) fence = null;
            }
            else if (isFence)
            {
                fence = opener;
            }
            else if (cursorAt == lineEnd)
            {
                delimiters = 0;
                brackets = 0;
            }
            else
            {
                var depth = 0;
                var cursor = cursorAt;
                while (cursor < lineEnd)
                {
                    var code = b[cursor];
                    if (code == '>')
                    {
                        depth++;
                        cursor++;
                    }
                    else if (code is '-' or '*' or '+' && cursor + 1 < lineEnd && Space(b[cursor + 1]))
                    {
                        depth++;
                        cursor += 2;
                    }
                    else if (code is >= '0' and <= '9')
                    {
                        var digit = cursor + 1;
                        while (digit < lineEnd && digit - cursor < 9 && b[digit] is >= '0' and <= '9') digit++;
                        var mark = digit < lineEnd ? b[digit] : -1;
                        if (mark is '.' or ')' && digit + 1 < lineEnd && Space(b[digit + 1]))
                        {
                            depth++;
                            cursor = digit + 2;
                        }
                        else break;
                    }
                    else break;

                    while (cursor < lineEnd && Space(b[cursor])) cursor++;
                    if (depth > MaxNesting) return Verdict.TooComplex;
                }

                if (depth > DeepNesting) deep = true;
                if (depth > 0 && indent > MaxListIndent) return Verdict.TooComplex;
                // A list item or heading starts its own run of inline text.
                if (depth > 0 || (cursor < lineEnd && b[cursor] == '#'))
                {
                    delimiters = 0;
                    brackets = 0;
                }
                // A table row's cells are parsed one at a time, so nothing in them adds up across the paragraph.
                var row = cursorAt < lineEnd && b[cursorAt] == '|';
                if (!row)
                {
                    for (var index = cursor; index < lineEnd; index++)
                    {
                        var code = b[index];
                        if (code is '*' or '_')
                        {
                            if (code == '*' ? (index + 1 < lineEnd && !Space(b[index + 1])) : !Word(At(b, index - 1)))
                                delimiters++;
                        }
                        else if (code is '[' or '<')
                        {
                            brackets++;
                        }
                        if (delimiters > MaxDelimiters || brackets > MaxBrackets) return Verdict.TooComplex;
                    }
                    if (delimiters > DeepDelimiters) deep = true;
                }
            }

            // Runs of one character, fenced code included (preprocessors read it too).
            var runCode = -1;
            var run = 0;
            for (var index = start; index < lineEnd; index++)
            {
                var code = b[index];
                if (code == runCode)
                {
                    run++;
                    if (run > MaxRun || (run > MaxDelimiterRun && fence is null && code is '*' or '_'))
                        return Verdict.TooComplex;
                    if (run > DeepRun && code is '*' or '_') deep = true;
                }
                else
                {
                    runCode = code is ' ' or '\t' or '*' or '_' or '`' or '~' ? code : -1;
                    run = 1;
                }
            }

            start = end + 1;
        }
        return deep ? Verdict.Deep : Verdict.Simple;
    }
}
