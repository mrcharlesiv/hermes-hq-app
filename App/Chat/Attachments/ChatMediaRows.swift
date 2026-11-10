import UIKit

// Row building for photos and files (docs/spec/1x-attachments.md §7.3, §7.7): your bubble with its attachments
// (Telegram's media bubble shape, A7), the `image_generate` card, and the echo rule that keeps a generated image from
// showing twice. Called by `ChatRowBuilder` (off the main thread); pure.

nonisolated enum ChatMediaRows {
    /// Splits a message's attachments into photos (album) and file rows, in order.
    static func split(_ attachments: [MessageAttachment], context: MediaContext?) -> (media: [MediaItem], files: [FileItem]) {
        var media: [MediaItem] = []
        var files: [FileItem] = []
        for (index, a) in attachments.enumerated() {
            if a.kind == .image {
                media.append(MediaItem(attachment: a, index: index, context: context, label: a.name == "Photo" ? "Photo" : "Photo, \(a.name)"))
            } else {
                files.append(FileItem(attachment: a, index: index, context: context, detail: detail(a)))
            }
        }
        return (media, files)
    }

    static func detail(_ a: MessageAttachment) -> String {
        if a.kind == .folder { return "Folder" }
        if a.kind == .link { return "Link" }
        return MediaKinds.detail(name: a.name, bytes: a.byteSize)
    }

    /// Your message with attachments: one bubble, photos at its top, file rows, then the caption. The default question
    /// of a photo-only send draws no text (A4).
    static func userBubble(_ m: ChatMessage, text: String, attachments: [MessageAttachment], input: ChatRowBuilder.Input) -> ChatRow {
        let (media, files) = split(attachments, context: input.media.context)
        var shown = text
        if !media.isEmpty && ChatText.trimmed(text) == AttachmentSender.defaultQuestion { shown = "" }
        var bubble = BubbleRow(mine: true, text: shown, markdown: true, partIndex: 0, joinsAbove: false, joinsBelow: false, tail: false,
                               time: nil, pending: m.isPending, streaming: false, speaker: "You", expanded: true)
        bubble.media = media
        bubble.files = files
        var h = Hasher()
        h.combine(ChatRowBuilder.bubbleFingerprint(shown, mine: true, speaker: "You"))
        MediaLayout.hash(media, files, into: &h)
        return ChatRow(id: "\(m.id)|b0", messageId: m.id, scope: input.scope, fingerprint: h.finalize(), kind: .bubble(bubble),
                       gapAbove: ChatMetrics.turnGap, variant: 0)
    }

    /// The `image_generate` card for a call (spec §7.7): live (no result yet) or settled with an image; nil → the
    /// existing generic/failed step.
    static func generatedRow(_ m: ChatMessage, call: ToolCall, input: ChatRowBuilder.Input) -> ChatRow? {
        let running = call.state == .running && m.isStreaming
        var info = input.media.generated[m.id]?[call.id]
        if info == nil || (info?.source == nil && !running) {
            let args = call.argsText.flatMap { ChatJSON.parse(string: $0)?.object } ?? [:]
            info = running ? GeneratedImageInfo.from(args: args, result: nil, running: true) : nil
        }
        guard let info, call.state != .failed else { return nil }
        if info.source == nil && !running { return nil }
        let source: MessageAttachment.Source
        if let s = info.source {
            if let url = URL(string: s), url.scheme?.lowercased() == "https" { source = .remote(url) }
            else { source = .gateway(path: s) }
        } else {
            source = .tooLarge          // placeholder: nothing to load while it renders
        }
        let attachment = MessageAttachment(kind: .image, source: source, name: info.name, pixelWidth: info.pixelWidth,
                                           pixelHeight: info.pixelHeight)
        let item = MediaItem(attachment: attachment, index: -1, context: input.media.context,
                             label: info.source == nil ? "Rendering image" : "Image, \(info.name)", generated: info,
                             rendering: info.source == nil)
        var bubble = BubbleRow(mine: false, text: "", markdown: false, partIndex: 0, joinsAbove: false, joinsBelow: false, tail: false,
                               time: nil, pending: false, streaming: false, speaker: nil)
        bubble.media = [item]
        var h = Hasher()
        h.combine("generated")
        MediaLayout.hash([item], [], into: &h)
        return ChatRow(id: "\(m.id)|g\(call.id)", messageId: m.id, scope: input.scope, fingerprint: h.finalize(), kind: .bubble(bubble),
                       gapAbove: ChatMetrics.turnGap, variant: 0)
    }

    /// A finished card joined onto the finished cards just above it: one photo stack you swipe through, the viewer
    /// paging them all (owner, 2026-10-31: twenty icons drew as twenty cards, "the images aren't showing where I can
    /// swipe through them like we had"). Nil when `card` stands alone: the row above isn't this message's cards only,
    /// or either is still rendering (its card keeps the live frame until its picture lands, then joins).
    static func stacking(_ card: ChatRow, onto prior: ChatRow) -> ChatRow? {
        guard prior.messageId == card.messageId, case .bubble(var stack) = prior.kind, case .bubble(let next) = card.kind,
              !stack.mine, stack.text.isEmpty, stack.files.isEmpty, !stack.media.isEmpty,
              stack.media.allSatisfy({ $0.generated != nil && !$0.rendering }),
              next.media.count == 1, let item = next.media.first, item.generated != nil, !item.rendering else { return nil }
        stack.media = (stack.media + [item]).map(stackShaped)
        var h = Hasher()
        h.combine("generated")
        MediaLayout.hash(stack.media, [], into: &h)
        return ChatRow(id: prior.id, messageId: prior.messageId, scope: prior.scope, fingerprint: h.finalize(), kind: .bubble(stack),
                       gapAbove: prior.gapAbove, variant: prior.variant)
    }

    /// A stack shapes its cards by pixel size; a result without one (fal's URLs) takes its requested aspect.
    private static func stackShaped(_ item: MediaItem) -> MediaItem {
        guard let info = item.generated, (item.attachment.pixelWidth ?? 0) <= 0 || (item.attachment.pixelHeight ?? 0) <= 0 else { return item }
        var shaped = item
        shaped.attachment.pixelWidth = Int((info.ratio * 1000).rounded())
        shaped.attachment.pixelHeight = 1000
        return shaped
    }

    private static let imageSpan = try! NSRegularExpression(pattern: #"!\[[^\]\n]*\]\([^)\n]*\)"#)
    private static let mediaLink = try! NSRegularExpression(pattern: #"\[[^\]\n]*\]\(\s*#media:[^)\n]*\)"#)
    private static let mediaToken = try! NSRegularExpression(pattern: #"MEDIA:[ \t]*("[^"\n]+"|`[^`\n]+`|'[^'\n]+'|\S+)"#)

    /// A reply whose turn generated an image shows it once, in the card (spec §7.7; V:lib/generated-images.ts:87-125):
    /// once a generation succeeded, every embedded markdown image and media link in that message's prose goes (the
    /// model often restates a URL while the result holds the path, the web's rule), and so does any mention of the
    /// result's paths/URLs — `host_image`, `image` and `agent_visible_image` (a container backend's own path) — bare
    /// or as a `MEDIA:` directive (whole line or inline). Other `MEDIA:` files stay. The words around stay.
    static func droppingEchoes(_ text: String, generated: [String: GeneratedImageInfo]?) -> String {
        guard let generated, !generated.isEmpty else { return text }
        var sources = Set<String>()
        for info in generated.values {
            guard let source = info.source else { continue }      // still rendering: nothing to echo yet
            sources.insert(source)
            sources.formUnion(info.echoes)
        }
        sources = sources.filter { !$0.isEmpty }
        guard !sources.isEmpty else { return text }
        var next = text
        func strip(_ re: NSRegularExpression, _ template: String = "") {
            next = re.stringByReplacingMatches(in: next, range: NSRange(next.startIndex..., in: next), withTemplate: template)
        }
        if next.contains("![") { strip(imageSpan) }
        if next.contains("](") && next.contains("#media:") { strip(mediaLink) }
        if next.contains("MEDIA:") {
            // Only the echoes: a `MEDIA:` file the reply also sends (a CSV beside the picture) still shows.
            let ns = next as NSString
            var out = ""
            var last = 0
            for match in mediaToken.matches(in: next, range: NSRange(location: 0, length: ns.length)) {
                let value = AttachmentHydration.unquote(ns.substring(with: match.range(at: 1)))
                guard sources.contains(value) else { continue }
                out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
                last = match.range.location + match.range.length
            }
            if last > 0 { next = out + ns.substring(from: last) }
        }
        for source in sources where next.contains(source) {
            let escaped = NSRegularExpression.escapedPattern(for: source)
            guard let re = try? NSRegularExpression(pattern: #"(^|[\s(\[{])<?"# + escaped + #">?(?=$|[\s)\]},.!?])"#,
                                                    options: [.anchorsMatchLines]) else { continue }
            strip(re, "$1")
        }
        return next
    }
}
