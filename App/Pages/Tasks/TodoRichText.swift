// [tasks] A bot's words on a task (its notes, its ready line, what it made, the activity), drawn as the chat draws a
// reply: Markdown, a long run of "Name: …" sentences as lines (`TodoReadable`), a file it names as the file's name that
// opens it ("review-sheet-20261104.md", not "~/.hermes/profiles/research/notes/review-sheet-20261104.md"),
// and phone numbers and links that open. Owner 2026-11-04: "the way that some of the work was presented … needs to be
// improved".

import SwiftUI
import UIKit

enum TodoRich {
    /// `text` rendered at `style`'s size. `readable`: a bot's one-paragraph run is split into lines first.
    static func attributed(_ text: String, style: UIFont.TextStyle = .body, category: UIContentSizeCategory,
                           readable: Bool = true, color: UIColor? = nil) -> NSAttributedString {
        let source = readable ? TodoReadable.markdown(text) : text
        let rendered = NSMutableAttributedString(attributedString:
            PagesMarkdown.attributed(source, category: category, highlight: false, filePaths: true))
        let full = NSRange(location: 0, length: rendered.length)
        if style != .body {
            let traits = UITraitCollection(preferredContentSizeCategory: category)
            let ratio = HQFont.preferred(style, compatibleWith: traits).pointSize / HQFont.preferred(.body, compatibleWith: traits).pointSize
            rendered.enumerateAttribute(.font, in: full) { value, range, _ in
                guard let font = value as? UIFont else { return }
                rendered.addAttribute(.font, value: font.withSize((font.pointSize * ratio).rounded()), range: range)
            }
        }
        // The chat draws its own links (`.chatLink`); a text view taps `.link`.
        rendered.enumerateAttribute(.chatLink, in: full) { value, range, _ in
            if let url = value as? URL { rendered.addAttribute(.link, value: url, range: range) }
        }
        if let color {
            rendered.enumerateAttribute(.link, in: full) { value, range, _ in
                if value == nil { rendered.addAttribute(.foregroundColor, value: color, range: range) }
            }
        }
        shortenPaths(rendered)
        return rendered
    }

    /// A file link whose words are its whole path reads as the file's name (the link still holds the path).
    static func shortenPaths(_ text: NSMutableAttributedString) {
        var found: [(NSRange, String)] = []
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
            guard let url, let path = FileLinks.path(fromLink: url), let name = FileLinks.place(path).name, !name.isEmpty else { return }
            let words = (text.string as NSString).substring(with: range)
            guard words.count > name.count, words.hasSuffix(name), words.contains("/") || words.contains("\\") else { return }
            found.append((range, name))
        }
        for (range, name) in found.reversed() {
            text.replaceCharacters(in: range, with: name)
        }
    }
}

/// `AttributedTextView` for a task: file links open in Files (`open`), phone numbers and web links open as iOS opens them.
struct TodoRichTextView: View {
    var text: String
    var style: UIFont.TextStyle = .body
    var readable = true
    var color: UIColor? = nil
    var maxLines = 0
    var identifier: String?
    var open: (String) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        AttributedTextView(text: TodoRich.attributed(text, style: style, category: UIContentSizeCategory(typeSize), readable: readable, color: color),
                           maxLines: maxLines, identifier: identifier, detectors: [.link, .phoneNumber]) { url in
            guard let path = FileLinks.path(fromLink: url) else { return false }
            Haptics.play(.selection)
            open(path)
            return true
        }
    }
}

/// Notes folded to about ten lines, with Show More / Show Less (as Kanban's `FoldedMarkdown`).
struct TodoFoldedText: View {
    var text: String
    var lines = 10
    var identifier: String?
    var open: (String) -> Void
    /// A tap on the text opens it (and closes it again); no Show More line. The task's card, where "more" over the
    /// last line had read as a cut word and Show More on its own line as clutter (owner 2026-11-08). Its ellipsis
    /// says there is more; VoiceOver gets Show More as an action.
    var tapOpens = false
    @State private var unfolded = false
    @State private var width: CGFloat = 0
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let attributed = TodoRich.attributed(text, category: UIContentSizeCategory(typeSize))
        VStack(alignment: .leading, spacing: 6) {
            AttributedTextView(text: attributed, maxLines: unfolded ? 0 : lines, identifier: identifier,
                               detectors: [.link, .phoneNumber]) { url in
                guard let path = FileLinks.path(fromLink: url) else { return false }
                Haptics.play(.selection)
                open(path)
                return true
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .contentShape(Rectangle())
            .onTapGesture {
                guard tapOpens, unfolded || AttributedTextView.exceeds(attributed, lines: lines, width: width) else { return }
                PagesHaptics.selection()
                HQMotion.withAnimation(.snappy) { unfolded.toggle() }
            }
            .accessibilityAction(named: unfolded ? "Show Less" : "Show More") {
                guard tapOpens else { return }
                HQMotion.withAnimation(.snappy) { unfolded.toggle() }
            }
            if !tapOpens, unfolded || AttributedTextView.exceeds(attributed, lines: lines, width: width) {
                Button(unfolded ? "Show Less" : "Show More") {
                    PagesHaptics.selection()
                    HQMotion.withAnimation(.snappy) { unfolded.toggle() }
                }
                .font(Font.hq(.footnote).weight(.semibold))
                .buttonStyle(.borderless)
                .fixedSize()            // standing on the task's page (no card inset), its first letter had been cut
                .padding(.leading, 2)
            }
        }
    }
}
