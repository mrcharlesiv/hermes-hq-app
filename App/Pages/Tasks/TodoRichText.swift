// [tasks] A bot's words on a task (its notes, its ready line, what it made, the activity), drawn as the chat draws a
// reply: Markdown, a long run of "Name: …" sentences as lines (`TodoReadable`), a file it names as the file's name that
// opens it ("review-sheet-20261104.md", not "~/.hermes/profiles/research/notes/review-sheet-20261104.md"),
// and phone numbers and links that open. Owner 2026-11-04: "the way that some of the work was presented … needs to be
// improved".

import SwiftUI
import UIKit

enum TodoRich {
    /// Lightweight LRU-bounded cache so Markdown isn't re-parsed on every SwiftUI body evaluation.
    private static let cache = NSCache<NSString, NSAttributedString>()
    private static let configured: Void = { cache.countLimit = 128 }()

    /// `text` rendered at `style`'s size. `readable`: a bot's one-paragraph run is split into lines first.
    static func attributed(_ text: String, style: UIFont.TextStyle = .body, category: UIContentSizeCategory,
                           readable: Bool = true, color: UIColor? = nil) -> NSAttributedString {
        _ = configured
        let colorKey = color.map { String(ObjectIdentifier($0).hashValue) } ?? "-"
        let key = "\(style.rawValue)|\(category.rawValue)|\(readable ? 1 : 0)|\(colorKey)|\(text)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
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
        if text.count <= 16_000 { cache.setObject(rendered, forKey: key) }
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
    /// [tasks-first] A tap on the words that isn't on a link (a task's notes start writing).
    var onTap: (() -> Void)? = nil
    var open: (String) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        AttributedTextView(text: TodoRich.attributed(text, style: style, category: UIContentSizeCategory(typeSize), readable: readable, color: color),
                           maxLines: maxLines, identifier: identifier, detectors: [.link, .phoneNumber], openLink: { url in
            guard let path = FileLinks.path(fromLink: url) else { return false }
            Haptics.play(.selection)
            open(path)
            return true
        }, onTap: onTap)
    }
}
