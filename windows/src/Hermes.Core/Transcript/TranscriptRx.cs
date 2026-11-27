using System.Text.RegularExpressions;

namespace Hermes.Core.Transcripts;

/// HermesKit's `TRx` (HermesKit/Chat/Transcript/Deliveries.swift): a tiny wrapper so the ports read like the web's
/// regular expressions. .NET's Regex is close to NSRegularExpression (ICU); patterns are copied as they are.
internal sealed class TranscriptRx(string pattern, RegexOptions options = RegexOptions.None)
{
    public Regex Re { get; } = new(pattern, options | RegexOptions.CultureInvariant);

    public bool Test(string text) => Re.IsMatch(text);

    /// The groups of the first match (index 0 = the whole match); null where a group did not take part.
    public string?[]? Groups(string text)
    {
        var m = Re.Match(text);
        if (!m.Success) return null;
        var out_ = new string?[m.Groups.Count];
        for (var i = 0; i < m.Groups.Count; i++) out_[i] = m.Groups[i].Success ? m.Groups[i].Value : null;
        return out_;
    }

    public Match? First(string text) => Re.Match(text) is { Success: true } m ? m : null;

    public string Replace(string text, string template) => Re.Replace(text, template);

    public List<string> AllMatches(string text) => [.. Re.Matches(text).Select(m => m.Value)];
}

/// Small string helpers shared by the transcript ports (Swift's trimming and line splitting).
internal static class TxText
{
    /// Swift `.trimmingCharacters(in: .whitespaces)`: spaces and tabs (and other horizontal space), not line breaks.
    public static string TrimSpaces(string s) => s.Trim(HorizontalSpace);

    private static readonly char[] HorizontalSpace =
        [' ', '\t', (char)0xA0, (char)0x1680, (char)0x2000, (char)0x2001, (char)0x2002, (char)0x2003, (char)0x2004, (char)0x2005,
         (char)0x2006, (char)0x2007, (char)0x2008, (char)0x2009, (char)0x200A, (char)0x202F, (char)0x205F, (char)0x3000];

    // Built from numbers: a U+2028 escape in a C# literal reads as a line break in the source.
    private static readonly char[] NewlineChars = ['\n', '\r', '\v', '\f', (char)0x85, (char)0x2028, (char)0x2029];
    private static readonly Regex LineBreak = new("\r\n|[" + new string(NewlineChars) + "]", RegexOptions.CultureInvariant);

    public static bool IsNewline(char c) => Array.IndexOf(NewlineChars, c) >= 0;

    /// Swift `enumerateLines`: every line terminator splits; no trailing empty line.
    public static List<string> Lines(string text)
    {
        if (text.Length == 0) return [];
        var lines = LineBreak.Split(text).ToList();
        if (lines.Count > 0 && lines[^1].Length == 0) lines.RemoveAt(lines.Count - 1);
        return lines;
    }

    /// Swift `split(whereSeparator: \.isNewline)`: empty pieces omitted.
    public static List<string> NonEmptyLines(string text) => [.. text.Split(NewlineChars, StringSplitOptions.RemoveEmptyEntries)];

    public static string Cap(string s) => s.Length == 0 ? s : char.ToUpperInvariant(s[0]) + s[1..];

}
