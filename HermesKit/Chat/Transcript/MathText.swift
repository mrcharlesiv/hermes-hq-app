// [transcript] Math in a reply (docs/spec/3x-transcript.md §3.5, row L310). The web loads KaTeX lazily and shows a
// formula as its source until then. The native transcript has no web view and measures every row ahead of drawing,
// so (DECISION, spec §3.5) a bounded TeX subset is turned into readable Unicode text, and a formula that uses
// anything outside the subset is shown whole as its TeX source in the code font: never a half-converted mix.

import Foundation

nonisolated enum MathText {
    static let maxLength = 2_000

    struct Span: Equatable, Sendable {
        /// The range of the whole formula in the text, delimiters included.
        var range: Range<String.Index>
        /// The TeX between the delimiters.
        var source: String
        /// `$$…$$` or `\[…\]`: its own centred block.
        var block: Bool

        /// A formula taken out of a reply (`extract`).
        struct Taken: Equatable, Sendable {
            var source: String
            var block: Bool
            /// A display formula on lines of its own: its own centred paragraph.
            var ownParagraph: Bool
            /// As written, delimiters included.
            var written: String
        }
    }

    // MARK: Finding formulas

    /// The formulas in `text`, in order, never overlapping. `\(…\)`, `\[…\]` and `$$…$$` always; a single `$…$`
    /// only when it reads as math ("It costs $5 and $10" stays text). An unclosed delimiter is text.
    static func spans(in text: String) -> [Span] {
        guard text.contains("$") || text.contains("\\(") || text.contains("\\[") || text.contains("\\begin{") else { return [] }
        var out: [Span] = []
        var i = text.startIndex
        let end = text.endIndex
        func find(_ needle: String, from: String.Index) -> Range<String.Index>? { text.range(of: needle, range: from..<end) }
        while i < end {
            let c = text[i]
            if c == "\\" {
                let next = text.index(after: i)
                guard next < end else { break }
                if text[next] == "(" || text[next] == "[" {
                    let block = text[next] == "["
                    let open = text.index(after: next)
                    if let close = find(block ? "\\]" : "\\)", from: open) {
                        let source = String(text[open..<close.lowerBound])
                        if !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, block || !source.contains("\n\n") {
                            out.append(Span(range: i..<close.upperBound, source: source.trimmingCharacters(in: .whitespacesAndNewlines), block: block))
                            i = close.upperBound
                            continue
                        }
                    }
                }
                // A math environment written bare, with no `$$` or `\[` around it (tester 2026-11-09: models write
                // `\begin{align}…\end{align}` on its own lines): a display formula, its `\begin` and `\end` kept.
                if text[next] == "b", let name = bareEnvironment(text, at: i),
                   let close = find("\\end{\(name)}", from: next) {
                    let source = String(text[i..<close.upperBound])
                    if source.count <= maxLength {
                        out.append(Span(range: i..<close.upperBound, source: source, block: true))
                        i = close.upperBound
                        continue
                    }
                }
                // An escaped character (including "\$") is never a delimiter.
                i = text.index(after: next)
                continue
            }
            if c == "$" {
                let next = text.index(after: i)
                if next < end, text[next] == "$" {
                    let open = text.index(after: next)
                    if open < end, !priceTier(text, at: open), let close = find("$$", from: open) {
                        let source = String(text[open..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !source.isEmpty {
                            out.append(Span(range: i..<close.upperBound, source: source, block: true))
                            i = close.upperBound
                            continue
                        }
                    }
                    i = text.index(after: next)
                    continue
                }
                if let close = inlineClose(text, open: i) {
                    let source = String(text[next..<close])
                    out.append(Span(range: i..<text.index(after: close), source: source, block: false))
                    i = text.index(after: close)
                    continue
                }
            }
            i = text.index(after: i)
        }
        return out
    }

    /// The environments that are math wherever they stand.
    static let bareEnvironments: Set<String> = [
        "align", "align*", "aligned", "equation", "equation*", "gather", "gather*", "gathered", "multline", "multline*",
        "eqnarray", "eqnarray*", "cases", "matrix", "pmatrix", "bmatrix", "vmatrix", "Bmatrix", "Vmatrix", "split",
    ]

    /// The name of the math environment a `\begin{` at `at` opens, if it is one.
    private static func bareEnvironment(_ text: String, at: String.Index) -> String? {
        let rest = text[at...]
        guard rest.hasPrefix("\\begin{"), let close = rest.firstIndex(of: "}") else { return nil }
        let name = String(rest[rest.index(rest.startIndex, offsetBy: 7)..<close])
        return bareEnvironments.contains(name) ? name : nil
    }

    /// A price tier, not a formula: "$$," "$$$" "$$-$$$" (a bot's restaurant shortlist, 2026-11-04, drew everything
    /// between "~$$, OpenTable" and "$$-$$$" as one display formula). `open` is just past the opening `$$`.
    private static func priceTier(_ text: String, at open: String.Index) -> Bool {
        let c = text[open]
        if "$,.;:)!?".contains(c) { return true }
        let after = text.index(after: open)
        return c == "-" && after < text.endIndex && text[after] == "$"
    }

    /// The closing `$` of an inline formula opened at `open`, when the piece reads as math: the opening `$` is not
    /// followed by whitespace, the closing one is not preceded by whitespace and not followed by a digit, the content
    /// is at most 200 characters on one line and holds at least one of `\ ^ _ = { }`.
    private static func inlineClose(_ text: String, open: String.Index) -> String.Index? {
        var i = text.index(after: open)
        let end = text.endIndex
        guard i < end, !text[i].isWhitespace else { return nil }
        var count = 0
        var mathy = false
        while i < end, count <= 200 {
            let c = text[i]
            if c.isNewline { return nil }
            if c == "\\" {
                mathy = true
                let next = text.index(after: i)
                guard next < end else { return nil }
                i = text.index(after: next); count += 2
                continue
            }
            if c == "$" {
                let before = text[text.index(before: i)]
                let after = text.index(after: i)
                if before.isWhitespace || count == 0 { return nil }
                if after < end, text[after].isNumber { return nil }
                return mathy ? i : nil
            }
            if "^_={}".contains(c) { mathy = true }
            i = text.index(after: i); count += 1
        }
        return nil
    }

    // MARK: Taking formulas out before Markdown sees them

    /// Markdown would eat a formula's `_`, `*` and `\(` (emphasis, escapes), so the renderer takes each formula out
    /// first and puts a token in its place: `inlineOpen` + index + `close`, or `blockOpen` + index + `close` for a
    /// display formula, which stands on its own paragraph when it had its own lines. Private-use characters, so no
    /// Markdown rule and no reply text can make or break one. Fenced code and inline code are left as they are.
    static let inlineOpen: Character = "\u{E000}"
    static let blockOpen: Character = "\u{E002}"
    static let close: Character = "\u{E001}"

    struct Extracted: Sendable {
        var text: String
        var formulas: [Span.Taken]
    }

    static func extract(_ text: String) -> Extracted {
        guard text.contains("$") || text.contains("\\(") || text.contains("\\[") || text.contains("\\begin{") else {
            return Extracted(text: text, formulas: [])
        }
        var formulas: [Span.Taken] = []
        var out = ""
        // Fenced code passes through untouched; the prose between fences is scanned whole (a display formula spans lines).
        var prose = ""
        var fence: String?
        func flushProse() {
            guard !prose.isEmpty else { return }
            out += takeFormulas(prose, into: &formulas)
            prose = ""
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (n, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let piece = String(raw) + (n < lines.count - 1 ? "\n" : "")
            if let f = fence {
                out += piece
                if line.hasPrefix(f) && line.trimmingCharacters(in: CharacterSet(charactersIn: String(f.first!))).isEmpty { fence = nil }
                continue
            }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                flushProse()
                fence = String(line.prefix(while: { $0 == line.first }))
                out += piece
                continue
            }
            prose += piece
        }
        flushProse()
        return Extracted(text: out, formulas: formulas)
    }

    /// Prose with its formulas swapped for tokens; inline code spans (`` `…` ``) are skipped.
    private static func takeFormulas(_ prose: String, into formulas: inout [Span.Taken]) -> String {
        guard prose.contains("$") || prose.contains("\\(") || prose.contains("\\[") || prose.contains("\\begin{") else { return prose }
        var out = ""
        var plain = ""
        func flushPlain() {
            guard !plain.isEmpty else { return }
            var cursor = plain.startIndex
            for span in spans(in: plain) {
                let before = plain[cursor..<span.range.lowerBound]
                // A display formula on lines of its own becomes its own paragraph (centred); one inside a sentence reads
                // inline.
                let ownLine = span.block && (before.isEmpty || before.last == "\n" || before.reversed().prefix { $0 != "\n" }.allSatisfy(\.isWhitespace))
                    && (span.range.upperBound == plain.endIndex || plain[span.range.upperBound...].prefix { $0 != "\n" }.allSatisfy(\.isWhitespace))
                out += before
                let index = formulas.count
                formulas.append(Span.Taken(source: span.source, block: span.block, ownParagraph: ownLine,
                                           written: String(plain[span.range])))
                if ownLine {
                    out += "\n\n" + String(blockOpen) + String(index) + String(close) + "\n\n"
                } else {
                    out += String(inlineOpen) + String(index) + String(close)
                }
                cursor = span.range.upperBound
            }
            out += plain[cursor...]
            plain = ""
        }
        var i = prose.startIndex
        while i < prose.endIndex {
            if prose[i] == "`" {
                // A code span: the same run of backticks closes it (CommonMark); unclosed, the backticks are text.
                var j = i
                while j < prose.endIndex, prose[j] == "`" { j = prose.index(after: j) }
                let ticks = String(prose[i..<j])
                if let end = prose.range(of: ticks, range: j..<prose.endIndex) {
                    flushPlain()
                    out += prose[i..<end.upperBound]
                    i = end.upperBound
                    continue
                }
                plain += ticks
                i = j
                continue
            }
            plain.append(prose[i])
            i = prose.index(after: i)
        }
        flushPlain()
        return out
    }

    /// The token's formula index, when `text` is exactly one display-formula token (its paragraph).
    static func blockToken(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.first == blockOpen, t.last == close else { return nil }
        return Int(t.dropFirst().dropLast())
    }

    /// Splits text holding tokens into its words and formulas, in order.
    enum Piece: Equatable, Sendable { case text(String), formula(Int) }

    static func pieces(_ text: String) -> [Piece] {
        guard text.contains(inlineOpen) || text.contains(blockOpen) else { return [.text(text)] }
        var out: [Piece] = []
        var run = ""
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c == inlineOpen || c == blockOpen, let end = text[i...].firstIndex(of: close),
               let index = Int(text[text.index(after: i)..<end]) {
                if !run.isEmpty { out.append(.text(run)); run = "" }
                out.append(.formula(index))
                i = text.index(after: end)
                continue
            }
            run.append(c)
            i = text.index(after: i)
        }
        if !run.isEmpty { out.append(.text(run)) }
        return out
    }

    /// Tokens back to the formulas as written (Copy, the Table sheet's text).
    static func restore(_ text: String, _ formulas: [Span.Taken]) -> String {
        guard !formulas.isEmpty else { return text }
        return pieces(text).map { piece in
            switch piece {
            case .text(let t): return t
            case .formula(let i): return i < formulas.count ? formulas[i].written : ""
            }
        }.joined()
    }

    /// VoiceOver: each formula reads "Formula: " + its source (spec §1.1).
    static func spoken(_ text: String) -> String {
        let found = spans(in: text)
        guard !found.isEmpty else { return text }
        var out = ""
        var cursor = text.startIndex
        for span in found {
            out += text[cursor..<span.range.lowerBound]
            out += "Formula: " + span.source
            cursor = span.range.upperBound
        }
        out += text[cursor...]
        return out
    }

    // MARK: TeX → readable text

    private static let symbols: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "varepsilon": "ε", "zeta": "ζ", "eta": "η",
        "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π",
        "rho": "ρ", "sigma": "σ", "tau": "τ", "upsilon": "υ", "phi": "φ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Phi": "Φ", "Psi": "Ψ",
        "Omega": "Ω",
        "times": "×", "cdot": "·", "pm": "±", "mp": "∓", "div": "÷", "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥", "neq": "≠",
        "ne": "≠", "approx": "≈", "equiv": "≡", "sim": "∼", "propto": "∝", "infty": "∞", "to": "→", "rightarrow": "→",
        "leftarrow": "←", "Rightarrow": "⇒", "Leftarrow": "⇐", "leftrightarrow": "↔", "implies": "⇒", "iff": "⇔",
        "sum": "∑", "prod": "∏", "int": "∫", "partial": "∂", "nabla": "∇", "forall": "∀", "exists": "∃", "in": "∈",
        "notin": "∉", "subset": "⊂", "subseteq": "⊆", "cup": "∪", "cap": "∩", "emptyset": "∅", "angle": "∠", "degree": "°",
        "circ": "∘", "ldots": "…", "cdots": "⋯", "dots": "…", "quad": "  ", "qquad": "    ", "ll": "≪", "gg": "≫",
        "langle": "⟨", "rangle": "⟩", "hbar": "ℏ", "ell": "ℓ", "prime": "′", "cdotp": "·", "land": "∧", "lor": "∨", "neg": "¬",
        "sin": "sin", "cos": "cos", "tan": "tan", "log": "log", "ln": "ln", "exp": "exp", "lim": "lim", "max": "max",
        "min": "min", "det": "det", "gcd": "gcd", "mod": "mod",
        ",": " ", ";": " ", ":": " ", "!": "", " ": " ", "{": "{", "}": "}", "%": "%", "$": "$", "&": "&", "#": "#", "_": "_",
        "|": "‖",
    ]
    private static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾", "n": "ⁿ", "i": "ⁱ",
    ]
    private static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎", "n": "ₙ", "i": "ᵢ",
    ]

    /// Names TeX sets upright (`\\sin`, `\\lim`, …); any other run of letters is variables, set italic (`MathStyle`).
    static let uprightNames: Set<String> = ["sin", "cos", "tan", "log", "ln", "exp", "lim", "max", "min", "det", "gcd", "mod"]

    /// The raised and lowered characters: drawn as they are, never italic.
    static let scriptCharacters: Set<Character> = Set(superscripts.values).union(subscripts.values)

    /// A fraction side as written after a "/": bracketed when it has an operator or space outside any brackets.
    static func bracketed(_ side: String) -> String {
        var level = 0
        for c in side {
            if c == "(" || c == "[" { level += 1 } else if c == ")" || c == "]" { level -= 1 }
            else if level == 0, " +−-=<>≤≥/,⁄±·×".contains(c) { return "(\(side))" }
        }
        return side
    }

    // MARK: Big operators' limits (`\sum_{i=1}^{n}`, `\lim_{n\to\infty}`)

    /// `\sum`, `\prod`, `\int`, `\lim`, … take a limit below (and often above) that a few tiny Unicode sub/superscript
    /// glyphs read as a cramped smear next to a tall operator glyph (screenshot review of the n20 revisit,
    /// 2026-10-31: "the Σ limits were tiny and cramped"). Their argument is wrapped in `limitBelowOpen`/`limitAboveOpen`
    /// … `limitClose` instead of being squeezed through `superscripts`/`subscripts`; `MathStyle` draws the wrapped text
    /// at a reduced size with a real baseline offset, so "i=1" still reads as "i=1".
    static let limitBaseOperators: Set<String> = ["∑", "∏", "∫", "lim", "max", "min", "gcd"]
    static let limitBelowOpen: Character = "\u{E003}"
    static let limitAboveOpen: Character = "\u{E004}"
    static let limitClose: Character = "\u{E005}"

    /// The formula as readable text; nil when it uses anything outside the subset (the caller then shows the source).
    /// Bounded: at most 2,000 characters and a few milliseconds.
    static func readable(_ source: String, block: Bool = false) -> String? {
        guard source.count <= maxLength else { return nil }
        var parser = Parser(chars: Array(source), block: block, deadline: DispatchTime.now().uptimeNanoseconds + 5_000_000)
        guard let out = parser.sequence(until: nil) else { return nil }
        guard parser.at >= parser.chars.count else { return nil }
        let tidy = out.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ") }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return tidy.isEmpty ? nil : tidy
    }

    private struct Parser {
        var chars: [Character]
        var block: Bool
        var deadline: UInt64
        var at = 0
        var depth = 0

        /// Parses until `close` ("}" for a group) or the end; nil = outside the subset.
        mutating func sequence(until close: Character?) -> String? {
            var out = ""
            while at < chars.count {
                if DispatchTime.now().uptimeNanoseconds > deadline { return nil }
                let c = chars[at]
                if let close, c == close { return out }
                if c == "}" { return nil }
                if c == "{" {
                    guard let inner = group() else { return nil }
                    out += inner
                    continue
                }
                if c == "^" || c == "_" {
                    at += 1
                    let piece = endsWithLimitOperator(out) ? limitScript(sub: c == "_") : script(sub: c == "_")
                    guard let piece else { return nil }
                    out += piece
                    continue
                }
                if c == "\\" {
                    guard let piece = command() else { return nil }
                    out += piece
                    continue
                }
                if c == "&" { at += 1; out += " "; continue }
                if c == "~" { at += 1; out += " "; continue }
                if c == "-" { at += 1; out += "−"; continue }
                if c == "*" { at += 1; out += "∗"; continue }
                if c == "'" { at += 1; out += "′"; continue }
                out.append(c)
                at += 1
            }
            return close == nil ? out : nil
        }

        /// A braced group at the cursor: its converted content.
        mutating func group() -> String? {
            guard at < chars.count, chars[at] == "{" else { return nil }
            depth += 1
            guard depth <= 24 else { return nil }
            at += 1
            guard let inner = sequence(until: "}") else { return nil }
            guard at < chars.count, chars[at] == "}" else { return nil }
            at += 1
            depth -= 1
            return inner
        }

        /// The raw text of a braced group (for `\text{…}`).
        mutating func rawGroup() -> String? {
            guard at < chars.count, chars[at] == "{" else { return nil }
            var level = 0
            var out = ""
            while at < chars.count {
                let c = chars[at]
                at += 1
                if c == "{" { level += 1; if level == 1 { continue } }
                if c == "}" { level -= 1; if level == 0 { return out } }
                out.append(c)
            }
            return nil
        }

        /// One argument: a group, a command, or a single character.
        mutating func argument() -> String? {
            while at < chars.count, chars[at] == " " { at += 1 }
            guard at < chars.count else { return nil }
            if chars[at] == "{" { return group() }
            if chars[at] == "\\" { return command() }
            defer { at += 1 }
            return String(chars[at])
        }

        mutating func script(sub: Bool) -> String? {
            guard let arg = argument() else { return nil }
            let table = sub ? MathText.subscripts : MathText.superscripts
            let mapped = arg.map { table[$0] }
            if !arg.isEmpty, mapped.allSatisfy({ $0 != nil }) { return String(mapped.compactMap { $0 }) }
            // Anything else stays written out.
            let plain = arg.count == 1 ? arg : "(\(arg))"
            return (sub ? "_" : "^") + plain
        }

        /// `out` (what has been converted so far at this level) currently ends with a big operator directly, or with
        /// that operator followed by its other limit (`\sum_{i=1}^{n}`: both the below and the above belong to the
        /// same ∑) — the `^`/`_` ahead of the cursor is a limit, not an ordinary sub/superscript.
        private func endsWithLimitOperator(_ out: String) -> Bool {
            var s = Substring(out)
            if s.last == MathText.limitClose, let open = s.lastIndex(where: { $0 == MathText.limitBelowOpen || $0 == MathText.limitAboveOpen }) {
                s = s[s.startIndex..<open]
            }
            return MathText.limitBaseOperators.contains { s.hasSuffix($0) }
        }

        /// A big operator's limit: its argument, wrapped for `MathStyle` to draw at a reduced size with a real
        /// baseline offset (below or above) instead of tiny Unicode sub/superscript glyphs.
        mutating func limitScript(sub: Bool) -> String? {
            guard let arg = argument(), !arg.isEmpty else { return nil }
            let open = sub ? MathText.limitBelowOpen : MathText.limitAboveOpen
            return String(open) + arg + String(MathText.limitClose)
        }

        mutating func command() -> String? {
            guard at < chars.count, chars[at] == "\\" else { return nil }
            at += 1
            guard at < chars.count else { return nil }
            var name = ""
            if chars[at].isLetter {
                while at < chars.count, chars[at].isLetter, chars[at].isASCII { name.append(chars[at]); at += 1 }
                // (TeX drops the spaces after a command; they are kept here, since they are what separates the words.)
            } else {
                name = String(chars[at]); at += 1
            }
            switch name {
            case "\\":
                return block ? "\n" : " "
            case "left", "right", "big", "Big", "bigg", "Bigg", "displaystyle", "textstyle", "limits", "nolimits":
                if at < chars.count, chars[at] == "." { at += 1 }
                return ""
            case "frac", "dfrac", "tfrac":
                guard let a = argument(), let b = argument() else { return nil }
                let simple: (String) -> Bool = { $0.count == 1 || $0.allSatisfy { $0.isNumber || $0.isLetter } && $0.count <= 3 }
                if simple(a) && simple(b) { return "\(a)⁄\(b)" }
                // Brackets only around a side that needs them: \frac{n(n+1)}{2} reads n(n+1)/2.
                return "\(MathText.bracketed(a))/\(MathText.bracketed(b))"
            case "sqrt":
                if at < chars.count, chars[at] == "[" { return nil }
                guard let a = argument() else { return nil }
                return "√(\(a))"
            case "text", "mathrm", "textbf", "mathbf", "mathit", "textit", "operatorname", "mathsf", "texttt":
                if name == "text" || name == "textbf" || name == "textit" || name == "texttt" { return rawGroup() }
                return group()
            case "bar", "overline":
                guard let a = argument() else { return nil }
                return a.count == 1 ? a + "\u{0305}" : "(\(a))\u{0305}"
            case "hat":
                guard let a = argument(), a.count == 1 else { return nil }
                return a + "\u{0302}"
            case "vec":
                guard let a = argument(), a.count == 1 else { return nil }
                return a + "\u{20D7}"
            case "dot":
                guard let a = argument(), a.count == 1 else { return nil }
                return a + "\u{0307}"
            case "binom":
                guard let a = argument(), let b = argument() else { return nil }
                return "C(\(a), \(b))"
            default:
                return MathText.symbols[name]
            }
        }
    }
}
