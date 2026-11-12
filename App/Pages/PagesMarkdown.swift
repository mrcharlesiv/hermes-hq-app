// Markdown in the pages (a job's prompt, a task's description and comments, a text file's Preview): the chat's own
// `MarkdownRenderer`, flattened into one attributed string for a selectable, non-scrolling text view.

import SwiftUI
import UIKit

nonisolated enum PagesMarkdown {
    /// A prompt is a template, not a document: "<cwd> <title>" are placeholders and "&lt;" means what it says, so `&`
    /// and `<` outside code are escaped (`promptMarkdown`, `S/fe-pages-r6.ts:4-11`).
    static func promptMarkdown(_ text: String) -> String {
        let code = RX.c(#"(```[\s\S]*?(?:```|$)|~~~[\s\S]*?(?:~~~|$)|`[^`\n]*`)"#)
        var out = ""
        var cursor = text.startIndex
        for match in code.all(text) {
            guard let range = Range(match.range, in: text) else { continue }
            out += escape(String(text[cursor..<range.lowerBound]))
            out += text[range]
            cursor = range.upperBound
        }
        out += escape(String(text[cursor...]))
        return out
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
    }

    /// The rendered blocks as one string: prose, quotes, code (monospaced, on a tint), tables read as lines.
    /// `filePaths`: a path the text names is a file link (`FileLinks`), as in a bot's reply.
    /// `tableCards`: a table is one `PreviewTableAttachment` character, for a page that lays the chat's table card over
    /// it (`PreviewTableCards`); otherwise it reads as lines.
    static func attributed(_ markdown: String, category: UIContentSizeCategory, highlight: Bool = true,
                           filePaths: Bool = false, tableCards: Bool = false) -> NSAttributedString {
        let style = ChatStyleCache.shared.style(for: category)
        let rendered = MarkdownRenderer.render(markdown, style: style, theme: .bot, highlight: highlight, filePaths: filePaths)
        let out = NSMutableAttributedString()
        func gap() {
            guard out.length > 0 else { return }
            out.append(NSAttributedString(string: "\n", attributes: [.font: HQFont.system(ofSize: 6)])) // a11y-font-ok: a spacer line, not text
        }
        for (index, block) in rendered.blocks.enumerated() {
            if index > 0 { out.append(NSAttributedString(string: "\n")); gap() }
            switch block {
            case .text(let text): out.append(text)
            case .quote(let text, _):
                let quoted = NSMutableAttributedString(attributedString: text)
                quoted.addAttribute(.foregroundColor, value: ChatPalette.label2, range: NSRange(location: 0, length: quoted.length))
                out.append(quoted)
            case .code(_, _, let text, _):
                let code = NSMutableAttributedString(attributedString: text)
                code.addAttribute(.backgroundColor, value: ChatPalette.inlineCodeFill, range: NSRange(location: 0, length: code.length))
                out.append(code)
            case .table(let table) where tableCards:
                out.append(NSAttributedString(attachment: PreviewTableAttachment(table: table, style: style)))
            case .table(let table): out.append(lined(table))
            case .spacer, .linkChip, .pageCard: break
            case .media(let refs):
                // Integration ([attachments] × pages): a reply's images and `MEDIA:` files read as their names here.
                out.append(NSAttributedString(string: refs.map(\.label).joined(separator: ", "),
                                              attributes: [.font: style.body, .foregroundColor: ChatPalette.label2]))
            }
        }
        return out
    }

    /// A table as lines with its columns lined up: a tab stop past each column's widest cell, numbers to the right. The
    /// bare tabs fell on the default 28 pt grid, so a header could run together ("ItemCount", 2026-10-29).
    private static func lined(_ table: MarkdownTable) -> NSAttributedString {
        let lines = [table.header] + table.rows
        let widths = (0..<table.columnCount).map { column in
            lines.map { column < $0.count ? ceil($0[column].size().width) : 0 }.max() ?? 0
        }
        var stops: [NSTextTab] = []
        var start: CGFloat = 0
        for column in widths.indices.dropFirst() {
            start += widths[column - 1] + 20
            let right = table.alignments[column] == .right || (column < table.numeric.count && table.numeric[column])
            stops.append(NSTextTab(textAlignment: right ? .right : .natural, location: right ? start + widths[column] : start))
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = stops
        let lined = NSMutableAttributedString(attributedString: table.flat)
        lined.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: lined.length))
        return lined
    }
}

/// A selectable, non-scrolling text view sized by SwiftUI; `maxLines` folds it (0 = all).
struct AttributedTextView: UIViewRepresentable {
    var text: NSAttributedString
    var maxLines: Int = 0
    var identifier: String?
    var detectors: UIDataDetectorTypes = [.link]
    /// A tapped link this page opens itself (a file link); false leaves it to iOS.
    var openLink: ((URL) -> Bool)?
    /// [tasks-first] A tap on the words that isn't on a link (a task's notes: the tap starts writing). The text view
    /// keeps taps from SwiftUI's own gesture, so it is the view's recognizer that says so.
    var onTap: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var openLink: ((URL) -> Bool)?
        var onTap: (() -> Void)?

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let onTap, let view = gesture.view as? UITextView, gesture.state == .ended else { return }
            // A tap on a link is the link's.
            let length = view.attributedText.length
            if length > 0, let position = view.closestPosition(to: gesture.location(in: view)) {
                let index = min(max(0, view.offset(from: view.beginningOfDocument, to: position)), length - 1)
                if view.attributedText.attribute(.link, at: index, effectiveRange: nil) != nil { return }
            }
            onTap()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
            guard case .link(let url) = textItem.content, let openLink, FileLinks.path(fromLink: url) != nil else { return defaultAction }
            return UIAction { _ in _ = openLink(url) }
        }
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.dataDetectorTypes = detectors
        view.delegate = context.coordinator
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.openLink = openLink
        context.coordinator.onTap = onTap
        if view.dataDetectorTypes != detectors { view.dataDetectorTypes = detectors }
        if view.attributedText != text { view.attributedText = text }
        view.textContainer.maximumNumberOfLines = maxLines
        view.textContainer.lineBreakMode = maxLines > 0 ? .byTruncatingTail : .byWordWrapping
        view.accessibilityIdentifier = identifier
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 320
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(size.height))
    }

    /// Whether `text` needs more than `lines` lines at `width` (Show All / Show More).
    static func exceeds(_ text: NSAttributedString, lines: Int, width: CGFloat) -> Bool {
        guard width > 0 else { return false }
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        var count = 0
        var index = 0
        let glyphs = manager.numberOfGlyphs
        while index < glyphs {
            var range = NSRange()
            manager.lineFragmentRect(forGlyphAt: index, effectiveRange: &range)
            index = NSMaxRange(range)
            count += 1
            if count > lines { return true }
        }
        return false
    }
}
