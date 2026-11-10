import Testing
import UIKit
@testable import HermesHQNative

/// [transcript] Typeset formulas (`MathTypeset`): the TeX a tester named (2026-11-09: inline, display, aligned, cases,
/// matrices) is set, not shown as source.
@Suite struct MathTypesetTests {
    static let samples: [(String, Bool)] = [
        (#"E = mc^2"#, false),
        (#"x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}"#, false),
        (#"\lVert \vec{v} \rVert = \sqrt{\sum_{i=1}^{n} v_i^2}"#, false),
        (#"\vec{v} \in \mathbb{R}^n"#, false),
        (#"\sum_{i=1}^{n} i = \frac{n(n+1)}{2} \qquad \int_{0}^{\infty} e^{-x^2}\,dx = \frac{\sqrt{\pi}}{2}"#, true),
        (#"\begin{aligned} (a+b)^2 &= (a+b)(a+b) \\ &= a^2 + 2ab + b^2 \end{aligned}"#, true),
        (#"f(x) = \begin{cases} x^2 & \text{if } x \ge 0 \\ -x & \text{otherwise} \end{cases}"#, true),
        (#"A = \begin{pmatrix} a & b \\ c & d \end{pmatrix}"#, true),
        (#"\begin{bmatrix} 1 & 0 \\ 0 & 1 \end{bmatrix} \begin{vmatrix} a & b \\ c & d \end{vmatrix} \begin{Bmatrix} 1 \\ 2 \end{Bmatrix}"#, true),
        (#"\begin{align} \nabla \cdot \mathbf{E} &= \frac{\rho}{\varepsilon_0} \\ \nabla \times \mathbf{B} &= \mu_0 \mathbf{J} \end{align}"#, true),
        (#"\begin{align*} a &= b \tag{1} \\ c &= d \label{eq:x} \end{align*}"#, true),
        (#"\begin{equation} \dfrac{\partial u}{\partial t} = \alpha \nabla^2 u \end{equation}"#, true),
        (#"\lim_{x \to 0} \frac{\sin x}{x} = 1"#, true),
        (#"\left( \frac{a}{b} \right)^n \cdot \binom{n}{k}"#, true),
        (#"\mathcal{L} = \operatorname{argmin}_\theta \mathbb{E}[\ell(\theta)]"#, false),
        (#"\hat{y} = \sigma(\mathbf{W}\mathbf{x} + \mathbf{b})"#, false),
        (#"P(A \mid B) = \frac{P(B \mid A)\,P(A)}{P(B)}"#, true),
        (#"\overline{z} \cdot \underbrace{a + b}_{c} \to \infty"#, true),
        (#"\begin{gather} a = b \\ c = d \end{gather}"#, true),
        (#"\boxed{x = 1} \quad \text{and} \quad \boldsymbol{\beta} \neq \emptyset"#, true),
        (#"\begin{array}{cc} a & b \\ c & d \end{array}"#, true),
        (#"a \equiv b \pmod{n}, \quad \mathrm{d}x, \quad x \mapsto x^2, \quad \forall \epsilon > 0\ \exists \delta"#, true),
    ]

    @Test func theSamplesAreSet() {
        let base = UIFont.systemFont(ofSize: 17)   // a11y-font-ok: a test's fixed size
        var failed: [String] = []
        for (source, block) in Self.samples where MathTypeset.attachment(source, block: block, base: base) == nil {
            failed.append(source)
        }
        #expect(failed.isEmpty, "not set: \(failed.joined(separator: "  ||  "))")
    }

    @Test func whatCantBeSetFallsBack() {
        let base = UIFont.systemFont(ofSize: 17)   // a11y-font-ok: a test's fixed size
        #expect(MathTypeset.attachment(#"\notacommand{x}"#, block: false, base: base) == nil)
        #expect(MathTypeset.attachment("", block: false, base: base) == nil)
    }

    /// A reply that writes an environment with no dollar signs around it (models often do) is still a formula.
    @Test func aBareEnvironmentIsAFormula() {
        let text = "So:\n\n\\begin{align}\na &= b \\\\\nc &= d\n\\end{align}\n\nDone."
        let taken = MathText.extract(text)
        #expect(taken.formulas.count == 1)
        #expect(taken.formulas.first?.source.hasPrefix("\\begin{align}") == true)
        #expect(taken.formulas.first?.ownParagraph == true, "on its own lines: its own centred paragraph")
        #expect(taken.formulas.first?.written.hasSuffix("\\end{align}") == true)
        #expect(MathText.extract("```\n\\begin{align}\na\n\\end{align}\n```").formulas.isEmpty, "code is left alone")
        #expect(MathText.extract("Streaming: \\begin{align} a &= b").formulas.isEmpty, "an unclosed one stays text")
    }

    @Test func anInlineFormulaFitsItsLine() throws {
        let base = UIFont.systemFont(ofSize: 17)   // a11y-font-ok: a test's fixed size
        let limit = (base.lineHeight * MathTypeset.inlineHeightRatio).rounded()
        let set = try #require(MathTypeset.attachment(#"x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}"#, block: false, base: base, maxHeight: limit))
        #expect(set.bounds.height <= limit + 4)
        for source in [#"\lVert \vec{v} \rVert = \sqrt{\sum_{i=1}^{n} v_i^2}"#, #"\vec{v} \in \mathbb{R}^n"#, #"e^{i\pi} + 1 = 0"#] {
            let set = MathTypeset.attachment(source, block: false, base: base, maxHeight: limit, maxWidth: MathTypeset.blockWidth)
            #expect(set != nil, "\(source)")
            #expect((set?.bounds.height ?? 0) <= limit + 4, "\(source)")
        }
    }
}
