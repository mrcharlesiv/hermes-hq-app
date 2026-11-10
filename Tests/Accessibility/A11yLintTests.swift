// [a11y] Source scans that keep the accessibility pass from eroding (docs/spec/3x-a11y.md §8.4). They read the
// source tree next to this file. Each failure names the file and line and says what to use instead.
//
// How to satisfy them in new code:
//   1. Text sizes: `UIFont.preferredFont`, `HQFont.scaled/mono/digits/style`, a SwiftUI text style, or
//      `.hqSymbolFont`. A size that truly must stay fixed (a letter inside a face, a spacer) carries
//      `// a11y-font-ok: <why>` on its line.
//   2. Settings: `HQAccessibility.current` / `HQMotion.reduced`, never `UIAccessibility.is…` (the DEBUG overrides
//      the UI tests use only work through them).
//   3. Motion: checked per call, not per file. Every animating line needs a Reduce Motion word (`HQMotion`,
//      `hqMotion`, `reduced`, `reduceMotion`) on it or within the 6 lines above it, or carries
//      `// motion-ok: <why>` (opacity only, a readout, guarded farther up: say where). `.transition(.opacity)` and
//      reads of a layer's animation (`.animation(forKey:`) need nothing.
//
// On the release train: these three scans read ALL of App/ and Shared/, and the other m9 streams were written
// without these rules. While the file `Tests/Accessibility/lint-soft.marker` exists, what the scans find is recorded
// as a known issue (listed in the test log) instead of failing the unit run. The Ship agent that merges the LAST
// stream converts the offenders and deletes the marker (docs/briefs/m9/a11y-report.md, "Integration").
//   4. Spoken labels are words: not a symbol name, no role ("… button"), and never the banned word.

import Foundation
import Testing

@Suite struct A11yLintTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private struct Line { let file: String; let number: Int; let text: String }

    /// True while `lint-soft.marker` sits beside this file: findings are known issues, not failures.
    private static let soft = FileManager.default.fileExists(
        atPath: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("lint-soft.marker").path)

    /// Fails with the list, or (soft) records it as a known issue and prints it for whoever converts the offenders.
    private func verdict(_ found: [String], _ advice: String, line: Int = #line) {
        guard !found.isEmpty else { return }
        let text = "\(advice)\n" + found.joined(separator: "\n")
        if Self.soft {
            print("[a11y-lint soft] \(found.count) — \(text)")
            withKnownIssue("a11y lint is soft until the last m9 stream is merged (lint-soft.marker)") { Issue.record(Comment(rawValue: text)) }
        } else {
            Issue.record(Comment(rawValue: text))
        }
    }

    private func sources(_ folders: [String] = ["App", "Shared"]) -> [(file: String, lines: [String])] {
        var out: [(String, [String])] = []
        for folder in folders {
            let base = Self.root.appendingPathComponent(folder)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let relative = url.path.replacingOccurrences(of: Self.root.path + "/", with: "")
                out.append((relative, text.components(separatedBy: "\n")))
            }
        }
        #expect(out.count > 100, "the source tree was found")
        return out
    }

    private func matches(_ pattern: String, skipping: [String] = [], where keep: (Line) -> Bool = { _ in true }) -> [String] {
        let regex = try! NSRegularExpression(pattern: pattern)
        var found: [String] = []
        for (file, lines) in sources() where !skipping.contains(where: file.contains) {
            for (index, text) in lines.enumerated() {
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { continue }
                guard regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else { continue }
                let line = Line(file: file, number: index + 1, text: text)
                if keep(line) { found.append("\(file):\(index + 1): \(trimmed.prefix(110))") }
            }
        }
        return found
    }

    /// A1: no text at a literal point size that ignores the user's text size.
    @Test func noFixedFontSizes() {
        let found = matches(#"(\.system\(size:|systemFont\(ofSize:|monospacedSystemFont\(ofSize:|monospacedDigitSystemFont\(ofSize:)\s*[0-9]"#,
                            skipping: ["App/Debug/", "App/Heads/", "App/Kit/Accessibility/", "/Debug/"]) { line in
            !["UIFontMetrics", "HQFont", "a11y-font-ok", "pointSize", "scaledValue"].contains(where: line.text.contains)
        }
        verdict(found, "Fixed font sizes. Use HQFont.scaled / a text style, or mark `// a11y-font-ok: <why>`.")
    }

    /// C6: one source for the settings.
    @Test func noDirectAccessibilitySettingReads() {
        let found = matches(#"UIAccessibility\.(is[A-Z][A-Za-z]+Enabled|is[A-Z][A-Za-z]+Running|buttonShapesEnabled|prefersCrossFadeTransitions)"#,
                            skipping: ["App/Kit/Accessibility/"])
        verdict(found, "Read HQAccessibility.current / HQMotion.reduced instead.")
        let posts = matches(#"UIAccessibility\.post\(notification:\s*\.announcement"#, skipping: ["App/Kit/Accessibility/"])
        verdict(posts, "Speak through HQAnnounce.say (logged for tests).")
    }

    /// E4: no call animates without having considered Reduce Motion. Per call: a file that mentions `HQMotion`
    /// somewhere proves nothing about its other animations.
    @Test func noUnguardedAnimations() {
        verdict(Self.unguardedAnimations(in: sources()), "Animate through HQMotion, or mark the line `// motion-ok: <why>`.")
    }

    static let motionWords = ["HQMotion", "hqMotion", "reduced", "reduceMotion", "ReduceMotion", "motion-ok"]

    static func unguardedAnimations(in files: [(file: String, lines: [String])]) -> [String] {
        let pattern = #"UIView\.animate|UIView\.transition|UIViewPropertyAnimator\(|withAnimation\(|withAnimation \{|\.animation\(|CASpringAnimation\(|CABasicAnimation\(|CAKeyframeAnimation\(|CADisplayLink\(|\.transition\("#
        let regex = try! NSRegularExpression(pattern: pattern)
        var found: [String] = []
        for (file, lines) in files {
            if ["App/Debug/", "ActivityMotionProbe.swift", "ChatPerfProbe.swift", "App/Kit/Accessibility/"].contains(where: file.contains) { continue }
            for (index, text) in lines.enumerated() where regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                // A read of a running animation, and a plain fade, move nothing.
                let harmless = text.replacingOccurrences(of: ".animation(forKey:", with: "").replacingOccurrences(of: ".transition(.opacity)", with: "")
                if regex.firstMatch(in: harmless, range: NSRange(harmless.startIndex..., in: harmless)) == nil { continue }
                let window = lines[max(0, index - 6)...index]
                if window.contains(where: { line in motionWords.contains(where: line.contains) }) { continue }
                found.append("\(file):\(index + 1): \(trimmed.prefix(100))")
            }
        }
        return found
    }

    /// The scan itself: a guard in the same file but far away does not excuse a call.
    @Test func theAnimationScanIsPerCall() {
        let far = ["if HQMotion.reduced { return }"] + Array(repeating: "let x = 1", count: 10) + ["UIView.animate(withDuration: 0.2) { v.transform = .identity }"]
        #expect(Self.unguardedAnimations(in: [("App/X.swift", far)]).count == 1, "a guard 11 lines up does not count")
        let near = ["guard !HQMotion.reduced else { return }", "let a = 1", "UIView.animate(withDuration: 0.2) { v.transform = .identity }"]
        #expect(Self.unguardedAnimations(in: [("App/X.swift", near)]).isEmpty)
        let marked = ["UIView.animate(withDuration: 0.2) { v.alpha = 0 }   // motion-ok: opacity only"]
        #expect(Self.unguardedAnimations(in: [("App/X.swift", marked)]).isEmpty)
        let reads = ["if layer.animation(forKey: \"pulse\") == nil { start() }", "Text(note).transition(.opacity)"]
        #expect(Self.unguardedAnimations(in: [("App/X.swift", reads)]).isEmpty)
        let moves = ["Text(note).transition(.move(edge: .top))", "withAnimation(.spring) { open = true }"]
        #expect(Self.unguardedAnimations(in: [("App/X.swift", moves)]).count == 2)
    }

    /// Spoken strings are words (spec §6.2 d 1) and never carry the banned word.
    @Test func spokenLabelsAreWords() {
        let regex = try! NSRegularExpression(pattern: #"accessibility(Label|Hint|Value)\s*(=|\()\s*(Text\()?"([^"\\]*)""#)
        let symbol = try! NSRegularExpression(pattern: #"^[a-z0-9]+(\.[a-z0-9]+)+$"#)
        var found: [String] = []
        for (file, lines) in sources(["App", "Shared", "NotificationService"]) {
            for (index, text) in lines.enumerated() {
                guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                      let range = Range(match.range(at: 4), in: text) else { continue }
                let literal = String(text[range])
                let kind = Range(match.range(at: 1), in: text).map { String(text[$0]) } ?? ""
                let place = "\(file):\(index + 1): \"\(literal)\""
                if literal.range(of: "dispatch", options: .caseInsensitive) != nil { found.append("banned word — \(place)") }
                guard kind == "Label", !literal.isEmpty else { continue }
                if symbol.firstMatch(in: literal, range: NSRange(literal.startIndex..., in: literal)) != nil { found.append("symbol name — \(place)") }
                if literal.lowercased().hasSuffix(" button") { found.append("names its role — \(place)") }
                if literal.hasSuffix(".") && !literal.hasSuffix("…") && !literal.contains(". ") && literal.count < 40 {
                    found.append("trailing full stop — \(place)")
                }
            }
        }
        #expect(found == [])
    }

    /// The word must not reach the user through any literal in a view either (bundle ids and storage keys are fine).
    @Test func theBannedWordIsInNoSpokenOrShownAccessibilityString() {
        let found = matches(#"accessibility(Label|Hint|Value|CustomAction).*"[^"]*[Dd]ispatch[^"]*""#) { line in
            // Swift's own `DispatchQueue` is code, not a string; only string literals count.
            let literals = line.text.components(separatedBy: "\"").enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
            return literals.contains { $0.range(of: "dispatch", options: .caseInsensitive) != nil && !$0.contains("com.") && !$0.contains("getdispatch") }
        }
        #expect(found == [])
    }
}
