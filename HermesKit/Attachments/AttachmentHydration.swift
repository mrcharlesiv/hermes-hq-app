// What a stored user row says about attachments (docs/spec/1x-attachments.md §7.1): `@image:` lines (Hermes' own
// form, `H:tui_gateway/session_history.py:133`), the older `[Image attached at: …]` hint, leading `@file:`/`@folder:`
// lines, non-voice `MEDIA:` lines, and image parts of a content array (inline `data:` bytes decoded into the inline
// store during the off-main fold; https; absolute paths). Plus the display key that matches your local bubble, the
// resume snapshot's in-flight prompt and the stored row to one another (rule 7). Pure; runs off the main thread.

import Foundation

nonisolated enum AttachmentHydration {
    struct Lifted: Sendable {
        /// The words left to show.
        var text: String
        /// The raw ref lines (`@file:…`, `@image:…`), for the cache's `attachmentRefs` (compatibility).
        var refs: [String]
        var attachments: [MessageAttachment]
    }

    private static let imageRE = try! NSRegularExpression(pattern: #"^@image:(`[^`\n]+`|"[^"\n]+"|'[^'\n]+'|\S+)$"#)
    private static let attachedAtRE = try! NSRegularExpression(pattern: #"^\[Image attached at: (.+)\]$"#)
    private static let mediaLineRE = try! NSRegularExpression(pattern: #"^MEDIA:\s*("[^"\n]+"|`[^`\n]+`|'[^'\n]+'|\S+)$"#)

    /// One pair of surrounding quotes (backticks, double or single) off a ref value.
    static func unquote(_ value: String) -> String {
        let v = value.trimmingCharacters(in: .whitespaces)
        guard v.count >= 2, let first = v.first, let last = v.last, first == last, "`\"'".contains(first) else { return v }
        return String(v.dropFirst().dropLast())
    }

    private static func firstGroup(_ re: NSRegularExpression, _ line: String) -> String? {
        let range = NSRange(line.startIndex..., in: line)
        guard let m = re.firstMatch(in: line, range: range), m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: line) else { return nil }
        return String(line[r])
    }

    private static func trimmedEnd(_ line: Substring) -> String {
        var s = String(line)
        while let last = s.last, last.isWhitespace { s.removeLast() }
        return s
    }

    /// Rules 1–5 on a user row's text: images (refs, `[Image attached at:]`, `MEDIA:` images), files (leading
    /// `@file:`/`@folder:` lines, `MEDIA:` files). Audio `MEDIA:` lines stay text (voice memos are the voice stream's).
    static func liftText(_ raw: String) -> Lifted {
        guard raw.contains("@") || raw.contains("[Image attached at:") || raw.contains("MEDIA:") else {
            return Lifted(text: raw, refs: [], attachments: [])
        }
        var images: [MessageAttachment] = []
        var mediaFiles: [MessageAttachment] = []
        var imageRefs: [String] = []
        var kept: [Substring] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = trimmedEnd(line)
            if t.hasPrefix("@image:") {
                let value = firstGroup(imageRE, t) ?? String(t.dropFirst("@image:".count))
                let path = unquote(value)
                if !path.isEmpty {
                    imageRefs.append(t)
                    images.append(MessageAttachment(kind: .image, source: .gateway(path: path), name: MediaKinds.name(ofPath: path, image: true)))
                    continue
                }
            }
            if t.hasPrefix("[Image attached at: "), let path = firstGroup(attachedAtRE, t)?.trimmingCharacters(in: .whitespaces), !path.isEmpty {
                images.append(MessageAttachment(kind: .image, source: .gateway(path: path), name: MediaKinds.name(ofPath: path, image: true)))
                continue
            }
            if t.hasPrefix("MEDIA:"), let value = firstGroup(mediaLineRE, t) {
                let path = unquote(value)
                let kind = MediaKinds.kind(ofName: path)
                if !path.isEmpty, kind != .audio, path.hasPrefix("/") || path.hasPrefix("~") {
                    if kind == .image {
                        images.append(MessageAttachment(kind: .image, source: .gateway(path: path), name: MediaKinds.name(ofPath: path, image: true)))
                    } else {
                        mediaFiles.append(MessageAttachment(kind: .file, source: .gateway(path: path), name: MediaKinds.name(ofPath: path, image: false)))
                    }
                    continue
                }
            }
            kept.append(line)
        }
        if !images.isEmpty {
            // `[screenshot]` / `[image]` describe the same pictures (session_history.py:111-148).
            kept.removeAll { $0 == "[screenshot]" || $0 == "[image]" }
        }
        let cleaned = images.isEmpty && mediaFiles.isEmpty && imageRefs.isEmpty ? raw : kept.joined(separator: "\n")
        let split = Hydration.splitLeadingAttachmentRefs(cleaned)
        var files: [MessageAttachment] = []
        for ref in split.refs {
            if ref.hasPrefix("@folder:") {
                let path = unquote(String(ref.dropFirst("@folder:".count)))
                files.append(MessageAttachment(kind: .folder, source: .gateway(path: path), name: MediaKinds.name(ofPath: path, image: false)))
            } else if ref.hasPrefix("@url:") {
                let url = unquote(String(ref.dropFirst("@url:".count)))
                files.append(MessageAttachment(kind: .link, source: .gateway(path: url), name: LinkText.display(url)))
            } else if ref.hasPrefix("@file:") {
                let path = unquote(String(ref.dropFirst("@file:".count)))
                files.append(MessageAttachment(kind: .file, source: .gateway(path: path), name: MediaKinds.name(ofPath: path, image: false)))
            }
        }
        let text = split.refs.isEmpty ? (images.isEmpty && mediaFiles.isEmpty ? cleaned : ChatText.trimmed(cleaned)) : split.text
        return Lifted(text: text, refs: split.refs + imageRefs, attachments: files + mediaFiles + images)
    }

    /// Rules 1–6 on a whole user row: its text (already the display content) and its raw `content` (image parts).
    static func liftUser(_ raw: String, content: JSONValue?) -> Lifted {
        var lifted = liftText(raw)
        let parts = imageParts(content)
        guard !parts.isEmpty else { return lifted }
        let decoded = parts.compactMap(attachment(fromPart:))
        let refImages = lifted.attachments.enumerated().filter { $0.element.kind == .image }
        if !refImages.isEmpty && refImages.count == decoded.count {
            // Hermes' native-vision form: N refs and N parts are the same pictures — the path's name, the part's bytes.
            for (k, entry) in refImages.enumerated() {
                let part = decoded[k]
                guard case .inline = part.source else { continue }
                var a = entry.element
                a.source = part.source
                a.pixelWidth = part.pixelWidth
                a.pixelHeight = part.pixelHeight
                a.byteSize = part.byteSize
                lifted.attachments[entry.offset] = a
            }
        } else {
            lifted.attachments += decoded
        }
        if lifted.text == "[image]" || lifted.text == "[screenshot]" { lifted.text = "" }
        return lifted
    }

    /// The image parts of a content array (`type` image_url / input_image / image, or an `image_url` key).
    static func imageParts(_ content: JSONValue?) -> [[String: JSONValue]] {
        guard case .array(let items)? = content else { return [] }
        return items.compactMap { item in
            guard let o = item.object, Hydration.isImagePart(o) else { return nil }
            return o
        }
    }

    /// One part as an attachment: a decoded `data:` image (into the inline store), an https URL, or an absolute path.
    static func attachment(fromPart part: [String: JSONValue]) -> MessageAttachment? {
        var value = part["image_url"]?["url"]?.string ?? part["image_url"]?.string ?? part["url"]?.string
            ?? part["source"]?["url"]?.string
        if value == nil, let source = part["source"]?.object, source["type"]?.string == "base64",
           let media = source["media_type"]?.string, let data = source["data"]?.string {
            value = "data:\(media);base64,\(data)"
        }
        guard let value else { return nil }
        return attachment(fromURLString: value)
    }

    /// Inline images in a reply's markdown are decoded only up to this size (spec §7.5).
    static let maxMarkdownInlineBytes = 8 << 20

    /// `![alt](data:image/…;base64,…)` in a reply (spec §7.5): decoded here, during the off-main fold, into the
    /// account's inline store, and the destination becomes `#media-inline:<key>`. The renderer then never decodes, and
    /// no message text or cache entry keeps the bytes. Larger than 8 MB: left to `Hydration.stripInlineDataURIs`
    /// (the alt text shows).
    static func inlineMarkdownImages(_ text: String) -> String {
        guard text.contains("](data:image/") else { return text }
        var out = ""
        var rest = Substring(text)
        while let marker = rest.range(of: "](data:image/") {
            let start = rest.index(marker.lowerBound, offsetBy: 2)
            guard let close = rest[start...].firstIndex(of: ")") else { break }
            out += rest[..<start]
            let uri = rest[start..<close]
            if uri.utf8.count / 4 * 3 <= maxMarkdownInlineBytes, let a = attachment(fromURLString: String(uri)),
               case .inline(let key) = a.source {
                out += "#media-inline:" + key.replacingOccurrences(of: "|", with: "%7C")
            } else {
                out += uri
            }
            rest = rest[close...]
        }
        out += rest
        return out
    }

    static func attachment(fromURLString value: String) -> MessageAttachment? {
        if value.hasPrefix("data:") {
            guard let comma = value.firstIndex(of: ","), value[..<comma].contains(";base64"), value.hasPrefix("data:image/") else { return nil }
            let encoded = value[value.index(after: comma)...]
            // Decoded size ≈ ¾ of the text: refuse before decoding anything too big.
            if encoded.utf8.count / 4 * 3 > InlineMediaStore.maxBytes {
                return MessageAttachment(kind: .image, source: .tooLarge, name: "Photo")
            }
            guard let data = Data(base64Encoded: String(encoded), options: .ignoreUnknownCharacters), !data.isEmpty else { return nil }
            let key = InlineMediaStore.current.store(data)         // the folded account's folder (spec §8.1)
            let size = PhotoNormalizer.pixelSize(of: data)
            return MessageAttachment(kind: .image, source: .inline(mediaKey: key), name: "Photo", pixelWidth: size?.0,
                                     pixelHeight: size?.1, byteSize: Int64(data.count))
        }
        if let url = URL(string: value), url.scheme?.lowercased() == "https" {
            return MessageAttachment(kind: .image, source: .remote(url), name: url.lastPathComponent.isEmpty ? "Photo" : url.lastPathComponent)
        }
        if value.hasPrefix("/") || value.hasPrefix("~") {
            return MessageAttachment(kind: .image, source: .gateway(path: value), name: MediaKinds.name(ofPath: value, image: true))
        }
        return nil
    }
}

nonisolated extension Hydration {
    /// The display key of a user message's text (spec §7.1 rule 7): the local bubble (your words or the default
    /// question), the resume snapshot's `inflight.user` (leading `@file:` lines, no `@image:` lines) and the stored row
    /// (both) all give the same key.
    static func userDisplayKey(_ text: String) -> String {
        ChatText.flat(AttachmentHydration.liftText(text).text)
    }
}
