using System.Diagnostics;
using System.Globalization;
using System.Text;

namespace Hermes.Core.Transcripts;

// Port of HermesKit/Chat/Transcript/MathText.swift (docs/spec/3x-transcript.md §3.5): finding formulas in a reply,
// taking them out before Markdown sees them, and a bounded TeX subset turned into readable Unicode text. A formula
// that uses anything outside the subset is shown whole as its TeX source in the code font: never a half-converted mix.
// Indices are UTF-16 offsets (Swift's are Character indices; the two agree for everything but astral characters).

/// A formula in a text: where it is (delimiters included), the TeX between the delimiters, and whether it is a display
/// formula (`$$…$$`, `\[…\]` or a bare math environment).
public sealed record MathSpan(int Start, int Length, string Source, bool Block)
{
    public int End => Start + Length;
}

/// A formula taken out of a reply (`MathText.Extract`). `OwnParagraph`: a display formula on lines of its own;
/// `Written`: as written, delimiters included.
public sealed record TakenFormula(string Source, bool Block, bool OwnParagraph, string Written);

public sealed record MathExtracted(string Text, IReadOnlyList<TakenFormula> Formulas);

/// A piece of text holding formula tokens: words, or the formula at an index.
public sealed record MathPiece(string? Text, int? Formula);

public static class MathText
{
    public const int MaxLength = 2_000;

    private static bool MayHaveMath(string text) =>
        text.Contains('$') || text.Contains("\\(", StringComparison.Ordinal) || text.Contains("\\[", StringComparison.Ordinal)
        || text.Contains("\\begin{", StringComparison.Ordinal);

    // Finding formulas

    /// The formulas in `text`, in order, never overlapping. `\(…\)`, `\[…\]` and `$$…$$` always; a single `$…$` only
    /// when it reads as math ("It costs $5 and $10" stays text). An unclosed delimiter is text.
    public static List<MathSpan> Spans(string text)
    {
        var out_ = new List<MathSpan>();
        if (!MayHaveMath(text)) return out_;
        var i = 0;
        var end = text.Length;
        int Find(string needle, int from) => text.IndexOf(needle, from, StringComparison.Ordinal);
        while (i < end)
        {
            var c = text[i];
            if (c == '\\')
            {
                var next = i + 1;
                if (next >= end) break;
                if (text[next] is '(' or '[')
                {
                    var block = text[next] == '[';
                    var open = next + 1;
                    var close = Find(block ? "\\]" : "\\)", open);
                    if (close >= 0)
                    {
                        var source = text[open..close];
                        if (source.Trim().Length > 0 && (block || !source.Contains("\n\n", StringComparison.Ordinal)))
                        {
                            out_.Add(new MathSpan(i, close + 2 - i, source.Trim(), block));
                            i = close + 2;
                            continue;
                        }
                    }
                }
                // A math environment written bare, with no `$$` or `\[` around it: a display formula, `\begin`/`\end` kept.
                if (text[next] == 'b' && BareEnvironment(text, i) is { } name)
                {
                    var endTag = "\\end{" + name + "}";
                    var close = Find(endTag, next);
                    if (close >= 0)
                    {
                        var stop = close + endTag.Length;
                        var source = text[i..stop];
                        if (source.Length <= MaxLength)
                        {
                            out_.Add(new MathSpan(i, stop - i, source, true));
                            i = stop;
                            continue;
                        }
                    }
                }
                // An escaped character (including "\$") is never a delimiter.
                i = next + 1;
                continue;
            }
            if (c == '$')
            {
                var next = i + 1;
                if (next < end && text[next] == '$')
                {
                    var open = next + 1;
                    if (open < end && !PriceTier(text, open) && Find("$$", open) is var close and >= 0)
                    {
                        var source = text[open..close].Trim();
                        if (source.Length > 0)
                        {
                            out_.Add(new MathSpan(i, close + 2 - i, source, true));
                            i = close + 2;
                            continue;
                        }
                    }
                    i = next + 1;
                    continue;
                }
                if (InlineClose(text, i) is { } inlineClose)
                {
                    out_.Add(new MathSpan(i, inlineClose + 1 - i, text[next..inlineClose], false));
                    i = inlineClose + 1;
                    continue;
                }
            }
            i++;
        }
        return out_;
    }

    /// The environments that are math wherever they stand.
    public static readonly IReadOnlySet<string> BareEnvironments = new HashSet<string>
    {
        "align", "align*", "aligned", "equation", "equation*", "gather", "gather*", "gathered", "multline", "multline*",
        "eqnarray", "eqnarray*", "cases", "matrix", "pmatrix", "bmatrix", "vmatrix", "Bmatrix", "Vmatrix", "split",
    };

    private static string? BareEnvironment(string text, int at)
    {
        if (string.CompareOrdinal(text, at, "\\begin{", 0, 7) != 0) return null;
        var close = text.IndexOf('}', at);
        if (close < 0) return null;
        var name = text[(at + 7)..close];
        return BareEnvironments.Contains(name) ? name : null;
    }

    /// A price tier, not a formula: "$$," "$$$" "$$-$$$". `open` is just past the opening `$$`.
    private static bool PriceTier(string text, int open)
    {
        var c = text[open];
        if ("$,.;:)!?".Contains(c)) return true;
        return c == '-' && open + 1 < text.Length && text[open + 1] == '$';
    }

    /// The closing `$` of an inline formula opened at `open`, when the piece reads as math: the opening `$` is not followed
    /// by whitespace, the closing one is not preceded by whitespace and not followed by a digit, the content is at most
    /// 200 characters on one line and holds at least one of `\ ^ _ = { }`.
    private static int? InlineClose(string text, int open)
    {
        var i = open + 1;
        var end = text.Length;
        if (i >= end || char.IsWhiteSpace(text[i])) return null;
        var count = 0;
        var mathy = false;
        while (i < end && count <= 200)
        {
            var c = text[i];
            if (TxText.IsNewline(c)) return null;
            if (c == '\\')
            {
                mathy = true;
                if (i + 1 >= end) return null;
                i += 2; count += 2;
                continue;
            }
            if (c == '$')
            {
                if (char.IsWhiteSpace(text[i - 1]) || count == 0) return null;
                if (i + 1 < end && char.IsNumber(text[i + 1])) return null;
                return mathy ? i : null;
            }
            if ("^_={}".Contains(c)) mathy = true;
            i++; count++;
        }
        return null;
    }

    // Taking formulas out before Markdown sees them

    /// Markdown would eat a formula's `_`, `*` and `\(`, so the renderer takes each formula out first and puts a token in
    /// its place: `InlineOpen` + index + `Close`, or `BlockOpen` + index + `Close` for a display formula. Private-use
    /// characters, so no Markdown rule and no reply text can make or break one. Code is left as it is.
    public const char InlineOpen = '';
    public const char BlockOpen = '';
    public const char Close = '';

    public static MathExtracted Extract(string text)
    {
        if (!MayHaveMath(text)) return new MathExtracted(text, []);
        var formulas = new List<TakenFormula>();
        var out_ = new StringBuilder();
        var prose = new StringBuilder();
        string? fence = null;
        void FlushProse()
        {
            if (prose.Length == 0) return;
            out_.Append(TakeFormulas(prose.ToString(), formulas));
            prose.Clear();
        }
        var lines = text.Split('\n');
        for (var n = 0; n < lines.Length; n++)
        {
            var raw = lines[n];
            var line = TxText.TrimSpaces(raw);
            var piece = raw + (n < lines.Length - 1 ? "\n" : "");
            if (fence is { } f)
            {
                out_.Append(piece);
                if (line.StartsWith(f, StringComparison.Ordinal) && line.Trim(f[0]).Length == 0) fence = null;
                continue;
            }
            if (line.StartsWith("```", StringComparison.Ordinal) || line.StartsWith("~~~", StringComparison.Ordinal))
            {
                FlushProse();
                fence = new string(line[0], line.TakeWhile(ch => ch == line[0]).Count());
                out_.Append(piece);
                continue;
            }
            prose.Append(piece);
        }
        FlushProse();
        return new MathExtracted(out_.ToString(), formulas);
    }

    /// Prose with its formulas swapped for tokens; inline code spans are skipped.
    private static string TakeFormulas(string prose, List<TakenFormula> formulas)
    {
        if (!MayHaveMath(prose)) return prose;
        var out_ = new StringBuilder();
        var plain = new StringBuilder();
        void FlushPlain()
        {
            if (plain.Length == 0) return;
            var p = plain.ToString();
            var cursor = 0;
            foreach (var span in Spans(p))
            {
                var before = p[cursor..span.Start];
                var lineBefore = before.LastIndexOf('\n') is var nl and >= 0 ? before[(nl + 1)..] : before;
                var afterEnd = p.IndexOf('\n', span.End) is var nl2 and >= 0 ? nl2 : p.Length;
                var ownLine = span.Block && (before.Length == 0 || before[^1] == '\n' || lineBefore.All(char.IsWhiteSpace))
                    && (span.End == p.Length || p[span.End..afterEnd].All(char.IsWhiteSpace));
                out_.Append(before);
                var index = formulas.Count;
                formulas.Add(new TakenFormula(span.Source, span.Block, ownLine, p[span.Start..span.End]));
                var id = index.ToString(CultureInfo.InvariantCulture);
                if (ownLine) out_.Append("\n\n").Append(BlockOpen).Append(id).Append(Close).Append("\n\n");
                else out_.Append(InlineOpen).Append(id).Append(Close);
                cursor = span.End;
            }
            out_.Append(p[cursor..]);
            plain.Clear();
        }
        var i = 0;
        while (i < prose.Length)
        {
            if (prose[i] == '`')
            {
                // A code span: the same run of backticks closes it (CommonMark); unclosed, the backticks are text.
                var j = i;
                while (j < prose.Length && prose[j] == '`') j++;
                var ticks = prose[i..j];
                var endAt = prose.IndexOf(ticks, j, StringComparison.Ordinal);
                if (endAt >= 0)
                {
                    FlushPlain();
                    out_.Append(prose[i..(endAt + ticks.Length)]);
                    i = endAt + ticks.Length;
                    continue;
                }
                plain.Append(ticks);
                i = j;
                continue;
            }
            plain.Append(prose[i]);
            i++;
        }
        FlushPlain();
        return out_.ToString();
    }

    /// The token's formula index, when `text` is exactly one display-formula token (its paragraph).
    public static int? BlockToken(string text)
    {
        var t = text.Trim();
        if (t.Length < 2 || t[0] != BlockOpen || t[^1] != Close) return null;
        return int.TryParse(t[1..^1], NumberStyles.None, CultureInfo.InvariantCulture, out var n) ? n : null;
    }

    /// Splits text holding tokens into its words and formulas, in order.
    public static List<MathPiece> Pieces(string text)
    {
        if (!text.Contains(InlineOpen) && !text.Contains(BlockOpen)) return [new MathPiece(text, null)];
        var out_ = new List<MathPiece>();
        var run = new StringBuilder();
        var i = 0;
        while (i < text.Length)
        {
            var c = text[i];
            if (c is InlineOpen or BlockOpen && text.IndexOf(Close, i) is var end and >= 0
                && int.TryParse(text.AsSpan(i + 1, end - i - 1), NumberStyles.None, CultureInfo.InvariantCulture, out var index))
            {
                if (run.Length > 0) { out_.Add(new MathPiece(run.ToString(), null)); run.Clear(); }
                out_.Add(new MathPiece(null, index));
                i = end + 1;
                continue;
            }
            run.Append(c);
            i++;
        }
        if (run.Length > 0) out_.Add(new MathPiece(run.ToString(), null));
        return out_;
    }

    /// Tokens back to the formulas as written (Copy, the Table sheet's text).
    public static string Restore(string text, IReadOnlyList<TakenFormula> formulas)
    {
        if (formulas.Count == 0) return text;
        return string.Concat(Pieces(text).Select(p => p.Text ?? (p.Formula is { } i && i < formulas.Count ? formulas[i].Written : "")));
    }

    /// Screen readers: each formula reads "Formula: " + its source (spec §1.1).
    public static string Spoken(string text)
    {
        var found = Spans(text);
        if (found.Count == 0) return text;
        var out_ = new StringBuilder();
        var cursor = 0;
        foreach (var span in found)
        {
            out_.Append(text, cursor, span.Start - cursor);
            out_.Append("Formula: ").Append(span.Source);
            cursor = span.End;
        }
        out_.Append(text, cursor, text.Length - cursor);
        return out_.ToString();
    }

    // TeX → readable text

    private static readonly Dictionary<string, string> Symbols = new()
    {
        ["alpha"] = "α", ["beta"] = "β", ["gamma"] = "γ", ["delta"] = "δ", ["epsilon"] = "ε", ["varepsilon"] = "ε", ["zeta"] = "ζ", ["eta"] = "η",
        ["theta"] = "θ", ["vartheta"] = "ϑ", ["iota"] = "ι", ["kappa"] = "κ", ["lambda"] = "λ", ["mu"] = "μ", ["nu"] = "ν", ["xi"] = "ξ", ["pi"] = "π",
        ["rho"] = "ρ", ["sigma"] = "σ", ["tau"] = "τ", ["upsilon"] = "υ", ["phi"] = "φ", ["varphi"] = "φ", ["chi"] = "χ", ["psi"] = "ψ", ["omega"] = "ω",
        ["Gamma"] = "Γ", ["Delta"] = "Δ", ["Theta"] = "Θ", ["Lambda"] = "Λ", ["Xi"] = "Ξ", ["Pi"] = "Π", ["Sigma"] = "Σ", ["Phi"] = "Φ", ["Psi"] = "Ψ",
        ["Omega"] = "Ω",
        ["times"] = "×", ["cdot"] = "·", ["pm"] = "±", ["mp"] = "∓", ["div"] = "÷", ["leq"] = "≤", ["le"] = "≤", ["geq"] = "≥", ["ge"] = "≥", ["neq"] = "≠",
        ["ne"] = "≠", ["approx"] = "≈", ["equiv"] = "≡", ["sim"] = "∼", ["propto"] = "∝", ["infty"] = "∞", ["to"] = "→", ["rightarrow"] = "→",
        ["leftarrow"] = "←", ["Rightarrow"] = "⇒", ["Leftarrow"] = "⇐", ["leftrightarrow"] = "↔", ["implies"] = "⇒", ["iff"] = "⇔",
        ["sum"] = "∑", ["prod"] = "∏", ["int"] = "∫", ["partial"] = "∂", ["nabla"] = "∇", ["forall"] = "∀", ["exists"] = "∃", ["in"] = "∈",
        ["notin"] = "∉", ["subset"] = "⊂", ["subseteq"] = "⊆", ["cup"] = "∪", ["cap"] = "∩", ["emptyset"] = "∅", ["angle"] = "∠", ["degree"] = "°",
        ["circ"] = "∘", ["ldots"] = "…", ["cdots"] = "⋯", ["dots"] = "…", ["quad"] = "  ", ["qquad"] = "    ", ["ll"] = "≪", ["gg"] = "≫",
        ["langle"] = "⟨", ["rangle"] = "⟩", ["hbar"] = "ℏ", ["ell"] = "ℓ", ["prime"] = "′", ["cdotp"] = "·", ["land"] = "∧", ["lor"] = "∨", ["neg"] = "¬",
        ["sin"] = "sin", ["cos"] = "cos", ["tan"] = "tan", ["log"] = "log", ["ln"] = "ln", ["exp"] = "exp", ["lim"] = "lim", ["max"] = "max",
        ["min"] = "min", ["det"] = "det", ["gcd"] = "gcd", ["mod"] = "mod",
        [","] = " ", [";"] = " ", [":"] = " ", ["!"] = "", [" "] = " ", ["{"] = "{", ["}"] = "}", ["%"] = "%", ["$"] = "$", ["&"] = "&", ["#"] = "#", ["_"] = "_",
        ["|"] = "‖",
    };
    private static readonly Dictionary<char, char> Superscripts = new()
    {
        ['0'] = '⁰', ['1'] = '¹', ['2'] = '²', ['3'] = '³', ['4'] = '⁴', ['5'] = '⁵', ['6'] = '⁶', ['7'] = '⁷', ['8'] = '⁸', ['9'] = '⁹',
        ['+'] = '⁺', ['-'] = '⁻', ['='] = '⁼', ['('] = '⁽', [')'] = '⁾', ['n'] = 'ⁿ', ['i'] = 'ⁱ',
    };
    private static readonly Dictionary<char, char> Subscripts = new()
    {
        ['0'] = '₀', ['1'] = '₁', ['2'] = '₂', ['3'] = '₃', ['4'] = '₄', ['5'] = '₅', ['6'] = '₆', ['7'] = '₇', ['8'] = '₈', ['9'] = '₉',
        ['+'] = '₊', ['-'] = '₋', ['='] = '₌', ['('] = '₍', [')'] = '₎', ['n'] = 'ₙ', ['i'] = 'ᵢ',
    };

    /// Names TeX sets upright (`\sin`, `\lim`, …); any other run of letters is variables, set italic.
    public static readonly IReadOnlySet<string> UprightNames = new HashSet<string> { "sin", "cos", "tan", "log", "ln", "exp", "lim", "max", "min", "det", "gcd", "mod" };

    /// The raised and lowered characters: drawn as they are, never italic.
    public static readonly IReadOnlySet<char> ScriptCharacters = new HashSet<char>(Superscripts.Values.Concat(Subscripts.Values));

    /// A fraction side as written after a "/": bracketed when it has an operator or space outside any brackets.
    public static string Bracketed(string side)
    {
        var level = 0;
        foreach (var c in side)
        {
            if (c is '(' or '[') level++;
            else if (c is ')' or ']') level--;
            else if (level == 0 && " +−-=<>≤≥/,⁄±·×".Contains(c)) return $"({side})";
        }
        return side;
    }

    /// `\sum`, `\prod`, `\int`, `\lim`, … take a limit below (and often above). Their argument is wrapped in
    /// `LimitBelowOpen`/`LimitAboveOpen` … `LimitClose`, for the drawing to set at a reduced size with a real baseline offset.
    public static readonly IReadOnlyList<string> LimitBaseOperators = ["∑", "∏", "∫", "lim", "max", "min", "gcd"];
    public const char LimitBelowOpen = '';
    public const char LimitAboveOpen = '';
    public const char LimitClose = '';

    /// The formula as readable text; null when it uses anything outside the subset (the caller then shows the source).
    /// Bounded: at most 2,000 characters and a few milliseconds.
    public static string? Readable(string source, bool block = false) =>
        Readable(source, block, Stopwatch.GetTimestamp, ReadableBudget);

    /// The time a formula gets, in `Stopwatch` ticks: 25 ms. The Mac allows 5 ms; a little more here so a cold start
    /// (JIT) never turns a formula into its source.
    internal static readonly long ReadableBudget = Stopwatch.Frequency / 40;

    /// `Readable` with its clock passed in, for this one call: `clock` is read once to start and again before every
    /// character the parser takes; past `budget` (in the clock's units) the formula is out of time and the whole
    /// source shows. Tests pass a step clock so the grammar is checked apart from how busy the machine is, and the
    /// running out of time is checked exactly. The budget is never off: it must be above zero.
    internal static string? Readable(string source, bool block, Func<long> clock, long budget)
    {
        ArgumentNullException.ThrowIfNull(clock);
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(budget);
        if (source.Length > MaxLength) return null;
        var start = clock();
        // A deadline past long.MaxValue counts as already spent, never as no limit.
        var deadline = start > long.MaxValue - budget ? long.MinValue : start + budget;
        var parser = new Parser(source, block, deadline, clock);
        if (parser.Sequence(null) is not { } out_) return null;
        if (parser.At < source.Length) return null;
        var tidy = string.Join("\n", out_.Split('\n')
            .Select(line => string.Join(" ", line.Split(' ', StringSplitOptions.RemoveEmptyEntries)))).Trim();
        return tidy.Length == 0 ? null : tidy;
    }

    private sealed class Parser(string chars, bool block, long deadline, Func<long> clock)
    {
        public int At;
        private int _depth;

        /// Parses until `close` ("}" for a group) or the end; null = outside the subset.
        public string? Sequence(char? close)
        {
            var out_ = new StringBuilder();
            while (At < chars.Length)
            {
                if (clock() > deadline) return null;
                var c = chars[At];
                if (close is { } cl && c == cl) return out_.ToString();
                if (c == '}') return null;
                if (c == '{')
                {
                    if (Group() is not { } inner) return null;
                    out_.Append(inner);
                    continue;
                }
                if (c is '^' or '_')
                {
                    At++;
                    var piece = EndsWithLimitOperator(out_.ToString()) ? LimitScript(c == '_') : Script(c == '_');
                    if (piece is null) return null;
                    out_.Append(piece);
                    continue;
                }
                if (c == '\\')
                {
                    if (Command() is not { } piece) return null;
                    out_.Append(piece);
                    continue;
                }
                switch (c)
                {
                    case '&' or '~': At++; out_.Append(' '); continue;
                    case '-': At++; out_.Append('−'); continue;
                    case '*': At++; out_.Append('∗'); continue;
                    case '\'': At++; out_.Append('′'); continue;
                }
                out_.Append(c);
                At++;
            }
            return close is null ? out_.ToString() : null;
        }

        /// A braced group at the cursor: its converted content.
        private string? Group()
        {
            if (At >= chars.Length || chars[At] != '{') return null;
            _depth++;
            if (_depth > 24) return null;
            At++;
            if (Sequence('}') is not { } inner) return null;
            if (At >= chars.Length || chars[At] != '}') return null;
            At++;
            _depth--;
            return inner;
        }

        /// The raw text of a braced group (for `\text{…}`).
        private string? RawGroup()
        {
            if (At >= chars.Length || chars[At] != '{') return null;
            var level = 0;
            var out_ = new StringBuilder();
            while (At < chars.Length)
            {
                var c = chars[At];
                At++;
                if (c == '{') { level++; if (level == 1) continue; }
                if (c == '}') { level--; if (level == 0) return out_.ToString(); }
                out_.Append(c);
            }
            return null;
        }

        /// One argument: a group, a command, or a single character.
        private string? Argument()
        {
            while (At < chars.Length && chars[At] == ' ') At++;
            if (At >= chars.Length) return null;
            if (chars[At] == '{') return Group();
            if (chars[At] == '\\') return Command();
            return chars[At++].ToString();
        }

        private string? Script(bool sub)
        {
            if (Argument() is not { } arg) return null;
            var table = sub ? Subscripts : Superscripts;
            if (arg.Length > 0 && arg.All(table.ContainsKey)) return new string([.. arg.Select(ch => table[ch])]);
            // Anything else stays written out.
            var plain = arg.Length == 1 ? arg : $"({arg})";
            return (sub ? "_" : "^") + plain;
        }

        /// `out` ends with a big operator, or with that operator and its other limit (`\sum_{i=1}^{n}`).
        private static bool EndsWithLimitOperator(string out_)
        {
            var s = out_;
            if (s.Length > 0 && s[^1] == LimitClose)
            {
                var open = s.LastIndexOfAny([LimitBelowOpen, LimitAboveOpen]);
                if (open >= 0) s = s[..open];
            }
            return LimitBaseOperators.Any(op => s.EndsWith(op, StringComparison.Ordinal));
        }

        /// A big operator's limit: its argument, wrapped for drawing at a reduced size with a real baseline offset.
        private string? LimitScript(bool sub)
        {
            if (Argument() is not { Length: > 0 } arg) return null;
            return (sub ? LimitBelowOpen : LimitAboveOpen) + arg + LimitClose;
        }

        private string? Command()
        {
            if (At >= chars.Length || chars[At] != '\\') return null;
            At++;
            if (At >= chars.Length) return null;
            string name;
            if (char.IsLetter(chars[At]))
            {
                var sb = new StringBuilder();
                while (At < chars.Length && char.IsAsciiLetter(chars[At])) sb.Append(chars[At++]);
                name = sb.ToString();
            }
            else name = chars[At++].ToString();
            switch (name)
            {
                case "\\":
                    return block ? "\n" : " ";
                case "left" or "right" or "big" or "Big" or "bigg" or "Bigg" or "displaystyle" or "textstyle" or "limits" or "nolimits":
                    if (At < chars.Length && chars[At] == '.') At++;
                    return "";
                case "frac" or "dfrac" or "tfrac":
                {
                    if (Argument() is not { } a || Argument() is not { } b) return null;
                    static bool Simple(string s) => s.Length == 1 || (s.All(char.IsLetterOrDigit) && s.Length <= 3);
                    if (Simple(a) && Simple(b)) return $"{a}⁄{b}";
                    // Brackets only around a side that needs them: \frac{n(n+1)}{2} reads n(n+1)/2.
                    return $"{Bracketed(a)}/{Bracketed(b)}";
                }
                case "sqrt":
                {
                    if (At < chars.Length && chars[At] == '[') return null;
                    return Argument() is { } a ? $"√({a})" : null;
                }
                case "text" or "textbf" or "textit" or "texttt":
                    return RawGroup();
                case "mathrm" or "mathbf" or "mathit" or "operatorname" or "mathsf":
                    return Group();
                case "bar" or "overline":
                    return Argument() is { } bar ? (bar.Length == 1 ? bar + "̅" : $"({bar})̅") : null;
                case "hat":
                    return Argument() is { Length: 1 } hat ? hat + "̂" : null;
                case "vec":
                    return Argument() is { Length: 1 } vec ? vec + "⃗" : null;
                case "dot":
                    return Argument() is { Length: 1 } dot ? dot + "̇" : null;
                case "binom":
                {
                    if (Argument() is not { } a || Argument() is not { } b) return null;
                    return $"C({a}, {b})";
                }
                default:
                    return Symbols.GetValueOrDefault(name);
            }
        }
    }
}
