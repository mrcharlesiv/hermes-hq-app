import UIKit
import Markdown

// Media in a reply's markdown (docs/spec/1x-attachments.md §7.5): `MEDIA:` links (preprocessed to `#media:`),
// images `![alt](src)` and file-path links (`/…`, `~/…`, `file://…`, `C:\…`; V:components/assistant-ui/markdown-text.tsx
// :320-341). A paragraph of media only becomes a `.media` block; inside a sentence a media link keeps its words with a
// leading glyph and opens the viewer or the file preview. Pure; used by the markdown renderer off the main thread.

nonisolated enum MarkdownMedia {
    /// Inline `data:` images are decoded (by the history fold) only up to this size (spec §7.5).
    static let maxInlineBytes = AttachmentHydration.maxMarkdownInlineBytes

    static func isFilePath(_ dest: String) -> Bool {
        if dest.hasPrefix("/") && !dest.hasPrefix("//") { return true }
        if dest.hasPrefix("~/") || dest.lowercased().hasPrefix("file://") { return true }
        return dest.range(of: #"^[A-Za-z]:\\"#, options: .regularExpression) != nil
    }

    /// The media a link or image destination names, or nil for an ordinary link.
    static func ref(destination raw: String, title: String, image: Bool) -> MediaRef? {
        let dest = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if dest.hasPrefix("#media:") {
            let encoded = String(dest.dropFirst("#media:".count))
            let value = encoded.removingPercentEncoding ?? encoded
            if value.lowercased().hasPrefix("https://"), let url = URL(string: value) { return remote(url, title: title, image: true) }
            return path(value, title: title)
        }
        if dest.hasPrefix("#media-inline:") {
            // Written by the history fold (`AttachmentHydration.inlineMarkdownImages`): the bytes are already stored.
            let raw = String(dest.dropFirst("#media-inline:".count))
            let key = raw.removingPercentEncoding ?? raw
            return MediaRef(kind: .image, attachment: MessageAttachment(kind: .image, source: .inline(mediaKey: key), name: "Image"),
                            label: title.isEmpty ? "Image" : title)
        }
        // A `data:` image still in the text (a live reply, before its stored row is folded) is never decoded here: the
        // renderer can run on the main thread (spec §7.5). It shows its alt text until the turn-end read replaces it.
        if dest.hasPrefix("data:") { return nil }
        if isFilePath(dest) {
            var p = dest
            if p.lowercased().hasPrefix("file://") { p = URL(string: p)?.path ?? String(p.dropFirst(7)) }
            return path(p.removingPercentEncoding ?? p, title: title)
        }
        if image, let url = URL(string: dest), url.scheme?.lowercased() == "https" { return remote(url, title: title, image: true) }
        return nil
    }

    private static func path(_ p: String, title: String) -> MediaRef {
        let kind = MediaKinds.refKind(ofName: p)
        let name = MediaKinds.name(ofPath: p, image: kind == .image)
        let attachment = MessageAttachment(kind: kind == .image ? .image : .file, source: .gateway(path: p), name: name)
        return MediaRef(kind: kind, attachment: attachment, label: label(title, name: name, kind: kind))
    }

    private static func remote(_ url: URL, title: String, image: Bool) -> MediaRef? {
        let name = url.lastPathComponent.isEmpty ? "Image" : url.lastPathComponent
        // SVG is never fetched as an image (spec §8.4): it stays a link.
        if MediaKinds.ext(name) == "svg" { return nil }
        let attachment = MessageAttachment(kind: .image, source: .remote(url), name: name)
        return MediaRef(kind: .image, attachment: attachment, label: label(title, name: name, kind: .image))
    }

    private static func label(_ title: String, name: String, kind: MediaRef.Kind) -> String {
        // "Image: chart.png" (the preprocessed MEDIA wording) → the name.
        var t = title.trimmingCharacters(in: .whitespaces)
        for prefix in ["Image: ", "Video: ", "Audio: ", "File: "] where t.hasPrefix(prefix) { t = String(t.dropFirst(prefix.count)) }
        if t.isEmpty { t = name }
        return kind == .image ? (t == name ? "Photo, \(name)" : t) : t
    }

    /// A `MEDIA:` link's words inside a sentence: its name, without the "Image: " / "File: " the preprocessing put there.
    static func inlineTitle(_ title: String, ref: MediaRef) -> String {
        var t = title.trimmingCharacters(in: .whitespaces)
        for prefix in ["Image: ", "Video: ", "Audio: ", "File: "] where t.hasPrefix(prefix) { t = String(t.dropFirst(prefix.count)) }
        return t.isEmpty ? ref.attachment.name : t
    }

    /// The link a media ref taps through (`chatCellOpen(url:)`).
    static func linkURL(_ ref: MediaRef) -> URL? {
        switch ref.attachment.source {
        case .gateway(let path):
            return URL(string: "#media:" + (path.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? path))
        case .remote(let url):
            return URL(string: "#media:" + (url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""))
        case .inline(let key):
            return URL(string: "#media-inline:" + (key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key))
        default:
            return nil
        }
    }

    /// The media behind a tapped `#media:` / `#media-inline:` link, if it is one.
    static func ref(fromLink url: URL) -> MediaRef? {
        let s = url.absoluteString
        guard s.hasPrefix("#media:") || s.hasPrefix("#media-inline:") else { return nil }
        if s.hasPrefix("#media-inline:") {
            let key = String(s.dropFirst("#media-inline:".count))
            return ref(destination: "#media-inline:" + (key.removingPercentEncoding ?? key), title: "Image", image: true)
        }
        return ref(destination: s, title: "", image: false)
    }

    /// A 13 pt glyph (photo / film / waveform / doc) and a thin space before an inline media link.
    static func glyph(_ ref: MediaRef, font: UIFont, color: UIColor) -> NSAttributedString {
        let symbol: String
        switch ref.kind {
        case .image: symbol = "photo"
        case .video: symbol = "film"
        case .audio: symbol = "waveform"
        case .file: symbol = MediaKinds.glyph(MediaKinds.kind(ofName: ref.attachment.name))
        }
        let config = UIImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        guard let image = UIImage(systemName: symbol, withConfiguration: config)?.withTintColor(color, renderingMode: .alwaysOriginal) else {
            return NSAttributedString()
        }
        let attachment = NSTextAttachment(image: image)
        let h = font.capHeight
        attachment.bounds = CGRect(x: 0, y: (h - image.size.height) / 2, width: image.size.width, height: image.size.height)
        let out = NSMutableAttributedString(attachment: attachment)
        out.append(NSAttributedString(string: "\u{2009}", attributes: [.font: font]))
        return out
    }

    /// A paragraph of media only (media links, images, breaks, blank text) → its refs.
    static func mediaOnly(_ p: Paragraph) -> [MediaRef]? {
        var refs: [MediaRef] = []
        for child in p.children {
            switch child {
            case let l as Markdown.Link:
                guard let dest = l.destination, let ref = ref(destination: dest, title: l.plainText, image: false) else { return nil }
                refs.append(ref)
            case let i as Markdown.Image:
                guard let src = i.source, let ref = ref(destination: src, title: i.plainText, image: true) else { return nil }
                refs.append(ref)
            case is SoftBreak, is LineBreak:
                continue
            case let t as Markdown.Text:
                guard t.string.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            default:
                return nil
            }
        }
        return refs.isEmpty ? nil : refs
    }

    private static let mediaOnlyLine = try! NSRegularExpression(
        pattern: #"^\s*(?:MEDIA:\s*[`"']?(?:/|~/)[^\s`"']+[`"']?\s*)+$"#)
    private static let imageOnlyLine = try! NSRegularExpression(pattern: #"^\s*!\[[^\]\n]*\]\([^)\s]+\)\s*$"#)

    /// A source line holding only `MEDIA:` directives.
    static func isMediaOnlyLine(_ line: String) -> Bool {
        mediaOnlyLine.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    /// A source line holding only one markdown image.
    static func isImageOnlyLine(_ line: String) -> Bool {
        line.contains("![") && imageOnlyLine.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }
}

/// [attachments] The words a reply's picture shows when the gateway won't hand it over (spec §7.5): honest, no path.
nonisolated enum MediaUnavailable {
    static func words(_ error: MediaLoadError) -> String {
        switch error {
        case .forbidden: return "Image · your gateway keeps this file private"
        default: return "Image · not on your gateway"
        }
    }
}
