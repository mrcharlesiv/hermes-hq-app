using System.Text;
using System.Text.RegularExpressions;

namespace Hermes.Core.Settings;

/// What leaves the PC through Copy Diagnostics keeps the failure's own words and loses recognizable private values: a
/// port of HermesKit/Diagnostics/Redactor.swift (itself the web app's `src/diagnostics-redact.ts`), rule for rule and in
/// the same order (docs/spec/3x-diagnostics.md §5). Idempotent, and linear in the text's length (longer text is cut to
/// 64 K first). Offsets are UTF-16 code units, as in the web app and the Mac, so their test vectors give the same answers.
/// ICU's possessive quantifiers are .NET atomic groups here.
public static class DiagnosticRedactor
{
    public const string Mask = "[redacted]";
    public const int Limit = 64 * 1024;

    public static string Redact(string input)
    {
        var text = input;
        var cut = text.Length > Limit;
        if (cut) text = text[..Limit];
        // Overlapping rules can expose another match (a short value inside a long quote); a few passes settle it.
        for (var i = 0; i < 4; i++)
        {
            var safe = RedactOnce(text);
            if (safe == text) break;
            text = safe;
        }
        // A long quote left open is still echoed input. A lone apostrophe is usually one ("can't"), so it only counts
        // after our own cut.
        return OpenQuote(text, cut ? "\"'“‘`" : "\"“‘`", cut ? "\"'”’`" : "\"”’`");
    }

    // ---------------------------------------------------------------- patterns

    private static readonly string Quoted = string.Join("|",
        @"(?<!\\)""(?>[^""\\]*)(?>(?:\\[\s\S](?>[^""\\]*))*)""",
        @"(?<!\\)'(?>[^'\\]*)(?>(?:\\[\s\S](?>[^'\\]*))*)'",
        "“(?>[^“”]*)”",
        "‘(?>[^‘’]*)’",
        @"\x60(?>[^\x60]*)\x60",
        @"\\""(?>[^""\\]*)(?>(?:\\[^""](?>[^""\\]*))*)\\""");

    private const string Keys =
        "password|passwd|pwd|passphrase|secret|token|api[ _-]?key|x-api-key|private_key|credentials?|signature|sig|ticket|otp|session|sessionid|sid|authorization|cookie";

    /// A quote never closed (the error was cut inside a value): its value runs to the end of the text.
    private static readonly string Unclosed =
        @"(?<!\\)""(?>[^""]*)\z|(?<!\\)'(?>[^']*)\z|" + "“(?>[^”]*)\\z|‘(?>[^’]*)\\z|" + @"\x60(?>[^\x60]*)\z|\\""(?>[^""]*)\z";

    private static Regex Rx(string pattern, bool insensitive = false) =>
        new(pattern, RegexOptions.CultureInvariant | (insensitive ? RegexOptions.IgnoreCase : RegexOptions.None));

    private static readonly Regex Pem = Rx(@"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----[\s\S]*?(?:-----END (?:[A-Z0-9]+ )*PRIVATE KEY-----|\z)");
    private static readonly Regex QuotedRun = Rx(Quoted);
    private static readonly Regex Content = Rx(@"(\\?[""'](?:text|content|body|prompt|transcript|delta|input|output|arguments)\\?[""'][ \t\r\n]*:[ \t\r\n]*)(?:("
        + Quoted + @")|([\[{]))", true);
    private static readonly Regex Header = Rx(@"\b((?:Proxy-Authorization|Authorization|Set-Cookie|Cookie)[ \t]*:[ \t]*)[^\r\n]*", true);
    private static readonly Regex UserInfo = Rx(@"\b([a-z][a-z0-9+.-]{0,31}://)[^\s/?#@""'<>\x60" + "“”‘’" + "]*@", true);
    private static readonly Regex Assigned = Rx(@"(\b[A-Za-z0-9_]*?(?:" + Keys + @")(?:\\?[""'])?[ \t\r\n]*[:=][ \t\r\n]*)(?:" + Quoted + "|" + Unclosed
        + @"|\[redacted\]|[^\s,;""'\x60}\]\)\\]+)", true);
    private static readonly Regex Bearer = Rx(@"\b(Bearer)[ \t]+(?:\[redacted\]|[^\s,;""'`}\]\)]+)", true);
    private static readonly Regex Scheme = Rx(@"\b(Basic|Token)[ \t]+([A-Za-z0-9+/._~-]{12,}=*)", true);
    private static readonly Regex Provider = Rx(@"\b(?:sk-[A-Za-z0-9_-]{8,}|[rs]k_(?:live|test)_[A-Za-z0-9]{20,}|(?:xai-|gsk_|pplx-|r8_|hf_)[A-Za-z0-9]{20,}|gh[pousr]_[A-Za-z0-9_]{8,}|github_pat_[A-Za-z0-9_]{30,}|glpat-[A-Za-z0-9_-]{20,}|xox[abprs]-[A-Za-z0-9-]{8,}|AIza[0-9A-Za-z_-]{35}|(?:AKIA|ASIA)[0-9A-Z]{16}|eyJ(?>[A-Za-z0-9_-]{2,1024})\.(?>[A-Za-z0-9_-]+)\.[A-Za-z0-9_-]*)\b");
    private static readonly Regex LongRun = Rx(@"\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b|[A-Za-z0-9]{24,}", true);

    // ---------------------------------------------------------------- one pass

    private static string RedactOnce(string input)
    {
        var text = Replace(Pem, input, _ => Mask);
        // Long quoted text in an error is echoed input (a message, a body), not the error's own words.
        text = Replace(QuotedRun, text, m => m.Value.Length - (m.Value[0] == '\\' ? 4 : 2) > 80 ? Requote(m.Value, Mask) : null);
        text = RedactContent(text);
        text = Replace(Header, text, m => m.Groups[1].Value + Mask);
        text = Replace(UserInfo, text, m => m.Groups[1].Value + Mask + "@");
        // A URL's (or a /path's) query and fragment carry tickets, file paths and search text; the path stays.
        text = RedactQueries(text);
        text = Replace(Assigned, text, m => m.Groups[1].Value + Mask);
        text = Replace(Bearer, text, m => m.Groups[1].Value + " " + Mask);
        // "Token expired" and "Basic auth" are words; a credential after them has a digit, padding or mixed case.
        text = Replace(Scheme, text, m =>
        {
            var value = m.Groups[2].Value;
            var rest = value[1..];
            var secret = value.Any(char.IsAsciiDigit) || value.EndsWith('=')
                || (value.Any(char.IsAsciiLetterLower) && rest.Any(char.IsAsciiLetterUpper));
            return secret ? m.Groups[1].Value + " " + Mask : null;
        });
        text = Replace(Provider, text, _ => Mask);
        // UUID-shaped keys are indistinguishable from session ids in unstructured errors.
        text = Replace(LongRun, text, m =>
        {
            var run = m.Value;
            if (run.Contains('-')) return Mask;
            if (run.Any(char.IsAsciiDigit) && run.Any(char.IsAsciiLetter)) return Mask;
            return run.Length >= 32 && run.All(char.IsAsciiHexDigit) ? Mask : null;
        });
        return text;
    }

    /// A quoted run with `inner` between its own quote marks (\" is two characters).
    private static string Requote(string quoted, string inner)
    {
        var edge = quoted[0] == '\\' ? 2 : 1;
        return quoted[..edge] + inner + quoted[^edge..];
    }

    /// Every match replaced by what `with` answers; null keeps the match as it is.
    private static string Replace(Regex regex, string text, Func<Match, string?> with)
    {
        var matches = regex.Matches(text);
        if (matches.Count == 0) return text;
        var out_ = new StringBuilder(text.Length);
        var last = 0;
        foreach (Match match in matches)
        {
            if (match.Length == 0 || with(match) is not { } replacement) continue;
            out_.Append(text, last, match.Index - last);
            out_.Append(replacement);
            last = match.Index + match.Length;
        }
        out_.Append(text, last, text.Length - last);
        return out_.ToString();
    }

    // ---------------------------------------------------------------- content keys (`redactContent`, `bracketEnd`)

    private static string RedactContent(string text)
    {
        var out_ = new StringBuilder();
        var last = 0;
        while (last < text.Length)
        {
            var match = Content.Match(text, last);
            if (!match.Success) break;
            var prefix = match.Groups[1];
            var quote = match.Groups[2];
            var end = quote.Success ? match.Index + match.Length : BracketEnd(text, prefix.Index + prefix.Length);
            out_.Append(text, last, match.Index - last);
            out_.Append(prefix.Value);
            out_.Append(quote.Success ? Requote(quote.Value, Mask) : Mask);
            last = end;
        }
        if (last == 0) return text;
        out_.Append(text, Math.Min(last, text.Length), text.Length - Math.Min(last, text.Length));
        return out_.ToString();
    }

    /// A content key's array or object value, to its closing bracket (or the end of the text). Strings inside are
    /// skipped, so a bracket in one doesn't count.
    private static int BracketEnd(string text, int start)
    {
        var depth = 0;
        var at = start;
        while (at < text.Length)
        {
            var c = text[at];
            if (c == '"')
            {
                at += 1;
                while (at < text.Length && text[at] != '"') at += text[at] == '\\' ? 2 : 1;
            }
            else if (c is '[' or '{')
            {
                depth += 1;
            }
            else if (c is ']' or '}')
            {
                depth -= 1;
                if (depth == 0) return at + 1;
            }
            at += 1;
        }
        return text.Length;
    }

    // ---------------------------------------------------------------- queries and fragments

    /// A `?` or `#` counts when the run before it (back to a stop character or another `?`/`#`) holds a `/` that starts
    /// the text or follows something that is neither a word character nor `/`. It is masked up to a stop character or `)`.
    private static string RedactQueries(string text)
    {
        if (text.IndexOfAny(['?', '#']) < 0) return text;
        var out_ = new StringBuilder(text.Length);
        var path = false;
        var at = 0;
        while (at < text.Length)
        {
            var c = text[at];
            if (c is '?' or '#')
            {
                var end = at + 1;
                while (end < text.Length && !IsStop(text[end]) && text[end] != ')') end += 1;
                if (path && end > at + 1)
                {
                    out_.Append(c).Append(Mask);
                    at = end;
                    path = false;
                    continue;
                }
                path = false;
            }
            else if (IsStop(c))
            {
                path = false;
            }
            else if (c == '/')
            {
                if (at == 0 || !(IsWord(text[at - 1]) || text[at - 1] == '/')) path = true;
            }
            out_.Append(c);
            at += 1;
        }
        return out_.ToString();
    }

    private static bool IsWord(char c) => c is >= '0' and <= '9' or >= 'A' and <= 'Z' or >= 'a' and <= 'z' or '_';

    /// JavaScript's `\s` plus the quote marks and angle brackets of the web's STOP set.
    private static bool IsStop(char c) => (int)c switch
    {
        >= 0x09 and <= 0x0D or 0x20 or 0xA0 or 0x1680 or >= 0x2000 and <= 0x200A or 0x2028 or 0x2029 or 0x202F or 0x205F
            or 0x3000 or 0xFEFF => true,
        0x22 or 0x27 or 0x3C or 0x3E or 0x60 or 0x201C or 0x201D or 0x2018 or 0x2019 => true,
        _ => false,
    };

    // ---------------------------------------------------------------- open quote

    /// The first opening mark after the last closing one, with 80+ characters after it, masked to the end.
    private static string OpenQuote(string text, string opens, string closes)
    {
        var at = text.Length - 1;
        while (at >= 0 && !closes.Contains(text[at])) at -= 1;
        if (at < 0 || !opens.Contains(text[at]))
        {
            at += 1;
            while (at < text.Length && !opens.Contains(text[at])) at += 1;
        }
        if (at >= text.Length || text.Length - at - 1 < 80) return text;
        return text[..(at + 1)] + Mask;
    }
}
