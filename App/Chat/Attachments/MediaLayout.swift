import UIKit

// Exact media geometry (docs/spec/1x-attachments.md §7.3, §7.5, §7.7): album and single-photo frames, file rows and the
// generated-image card, all known before any pixel loads (heights never wait for images; spec §7.8). Pure and
// `nonisolated`, measured off the main thread with the rest of `TextLayout`.

/// One photo in a bubble or a reply's media block.
nonisolated struct MediaItem: Hashable, Sendable {
    var attachment: MessageAttachment
    /// Its index among the message's attachments (for the learnt-size write-back); -1 for reply markdown media.
    var index: Int
    /// Account, profile and session (media keys, downloads).
    var context: MediaContext?
    /// VoiceOver label ("Photo, chart.png", or a markdown image's alt text).
    var label: String
    /// An `image_generate` card: its aspect hint when the result has no pixel size, and whether the tool still runs.
    var generated: GeneratedImageInfo? = nil
    var rendering: Bool = false
}

/// One file row.
nonisolated struct FileItem: Hashable, Sendable {
    var attachment: MessageAttachment
    var index: Int
    var context: MediaContext?
    /// "PDF · 2.4 MB", "PDF", "Folder".
    var detail: String
}

/// Photos laid out together (an album, a single photo, a generated image): their container inside the bubble.
nonisolated struct MediaGroupLayout: @unchecked Sendable {
    /// In bubble coordinates.
    var frame: CGRect
    /// The container's corner radius; nil = clipped by the bubble's own outline (your bubble, a photo-only bubble).
    var radius: CGFloat?
    var tiles: [(item: MediaItem, frame: CGRect)]
    /// The photo is shown whole (aspect fit) on a blur of itself: a tall photo widened for its caption.
    var fits = false
    /// Several photos as a stack you swipe through (owner 2026-10-30): the box in the group that every card fits in.
    /// The cards behind fan out around it; the group keeps room above and below for their corners.
    var stack: CGRect? = nil
}

/// One file row inside a bubble.
nonisolated struct FileRowLayout: @unchecked Sendable {
    var item: FileItem
    /// In bubble coordinates.
    var frame: CGRect
    var circle: CGRect
    var name: CGRect
    var nameLines: Int
    var detail: CGRect
    var mine: Bool
}

nonisolated enum MediaLayout {
    static let gap: CGFloat = 2
    static let singleMax: CGFloat = 260
    static let singleMaxHeight: CGFloat = 320
    static let singleMinWidth: CGFloat = 150
    static let singleMinHeight: CGFloat = 100
    static let unknownHeight: CGFloat = 195
    static let replyMax: CGFloat = 280
    static let replyRadius: CGFloat = 12

    /// One photo's frame (spec §7.3): ≤ 260 wide, ≤ 320 tall (then ≥ 150 wide), ≥ 100 tall; unknown → 260 × 195.
    static func single(width pw: Int?, height ph: Int?, maxWidth maxW: CGFloat) -> CGSize {
        let cap = min(maxW, singleMax)
        guard let pw, let ph, pw > 0, ph > 0 else { return CGSize(width: floor(cap), height: unknownHeight) }
        var w = cap
        var h = w * CGFloat(ph) / CGFloat(pw)
        if h > singleMaxHeight {
            h = singleMaxHeight
            w = max(singleMinWidth, min(maxW, singleMaxHeight * CGFloat(pw) / CGFloat(ph)))
        }
        if h < singleMinHeight { h = singleMinHeight }
        return CGSize(width: floor(w), height: floor(h))
    }

    /// Frames for `sizes` (pixel sizes, nil when unknown) inside `maxWidth`, origin (0, 0), and the whole size.
    /// 2 → two squares; 3 → one w × w/2 cell over two squares; 4 → 2 × 2; ≥ 5 → rows of 3 squares, the last row's
    /// cells sharing its width. Every frame follows from the width alone (albums never wait for pixels).
    static func frames(sizes: [(Int?, Int?)], maxWidth: CGFloat) -> (frames: [CGRect], size: CGSize) {
        guard !sizes.isEmpty else { return ([], .zero) }
        if sizes.count == 1 {
            let s = single(width: sizes[0].0, height: sizes[0].1, maxWidth: maxWidth)
            return ([CGRect(origin: .zero, size: s)], s)
        }
        let w = floor(min(maxWidth, singleMax))
        var out: [CGRect] = []
        switch sizes.count {
        case 2:
            let side = floor((w - gap) / 2)
            out = [CGRect(x: 0, y: 0, width: side, height: side), CGRect(x: w - side, y: 0, width: side, height: side)]
        case 3:
            let topH = floor(w / 2)
            let side = floor((w - gap) / 2)
            out = [CGRect(x: 0, y: 0, width: w, height: topH),
                   CGRect(x: 0, y: topH + gap, width: side, height: side),
                   CGRect(x: w - side, y: topH + gap, width: side, height: side)]
        case 4:
            let side = floor((w - gap) / 2)
            for i in 0..<4 {
                out.append(CGRect(x: i % 2 == 0 ? 0 : w - side, y: CGFloat(i / 2) * (side + gap), width: side, height: side))
            }
        default:
            let side = floor((w - 2 * gap) / 3)
            let rows = (sizes.count + 2) / 3
            for r in 0..<rows {
                let start = r * 3
                let k = min(3, sizes.count - start)
                let y = CGFloat(r) * (side + gap)
                if k == 3 {
                    for c in 0..<3 {
                        let x = c == 2 ? w - side : CGFloat(c) * (side + gap)
                        out.append(CGRect(x: x, y: y, width: side, height: side))
                    }
                } else {
                    let cell = floor((w - CGFloat(k - 1) * gap) / CGFloat(k))
                    for c in 0..<k {
                        let x = c == k - 1 ? w - cell : CGFloat(c) * (cell + gap)
                        out.append(CGRect(x: x, y: y, width: cell, height: side))
                    }
                }
            }
        }
        let height = out.map(\.maxY).max() ?? 0
        return (out, CGSize(width: w, height: height))
    }

    // MARK: Photo stacks

    /// Room above and below a stack's card for the corners of the cards fanned out behind it. Sideways they reach into
    /// the margin beside the bubble (never more than ~12 pt), so the card lines up with the text and bubble edges.
    static let stackPadY: CGFloat = 10

    /// A stack's box (owner 2026-10-30: several photos "sit on top of each other where you can swipe through them"):
    /// one box for every photo, so the row never changes height as you flip. It takes the photos' middle shape (one
    /// photo's rules, `single`); each card is its own photo's shape inside it (`PhotoStackView.cardSize`).
    /// Unknown sizes make the 4:3 box. Returns the box's frame (origin `(0, stackPadY)`) and the group's size.
    static func stack(sizes: [(Int?, Int?)], maxWidth: CGFloat) -> (card: CGRect, size: CGSize) {
        let aspects = sizes.compactMap { w, h -> CGFloat? in
            guard let w, let h, w > 0, h > 0 else { return nil }
            return CGFloat(w) / CGFloat(h)
        }.sorted()
        var shape: (Int?, Int?) = (nil, nil)
        if !aspects.isEmpty {
            let k = aspects.count
            // The middle shape, halfway between the two middle ones in proportion (log) for an even count.
            let middle = k % 2 == 1 ? aspects[k / 2] : (aspects[k / 2 - 1] * aspects[k / 2]).squareRoot()
            shape = (Int((middle * 1000).rounded()), 1000)
        }
        let card = single(width: shape.0, height: shape.1, maxWidth: maxWidth)
        return (CGRect(x: 0, y: stackPadY, width: card.width, height: card.height),
                CGSize(width: card.width, height: card.height + 2 * stackPadY))
    }

    /// The generated-image card (spec §7.7): `w = min(column, 320)`, the result's aspect (else the requested one),
    /// at most 400 tall.
    static func generated(_ info: GeneratedImageInfo, column: CGFloat) -> CGSize {
        let ratio = max(0.1, info.ratio)
        var w = min(column, 320)
        var h = w / ratio
        if h > 400 {
            h = 400
            w = 400 * ratio
        }
        return CGSize(width: floor(w), height: floor(h))
    }

    // MARK: File rows

    static let rowPadV: CGFloat = 12
    static let rowLead: CGFloat = 12
    static let rowTrail: CGFloat = 12
    static let circle: CGFloat = 40
    static let circleGap: CGFloat = 10
    static let rowGap: CGFloat = 4

    static func nameFont(_ style: ChatStyle) -> UIFont {
        HQFont.face(ofSize: min(22, max(15, HQFont.preferred(.subheadline,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: style.category)).pointSize)), weight: .semibold)
    }

    static func detailFont(_ style: ChatStyle) -> UIFont {
        HQFont.preferred(.caption1, compatibleWith: UITraitCollection(preferredContentSizeCategory: style.category))
    }

    /// The width a row wants for its words (one-line name or detail), before capping.
    static func naturalRowWidth(_ item: FileItem, style: ChatStyle, reserve: CGFloat = 0) -> CGFloat {
        let name = ceil((item.attachment.name as NSString).size(withAttributes: [.font: nameFont(style)]).width)
        let detail = ceil((item.detail as NSString).size(withAttributes: [.font: detailFont(style)]).width) + reserve
        return rowLead + circle + circleGap + max(name, detail) + rowTrail
    }

    /// One row at `width` (12 pt top/bottom padding, name up to 2 lines, detail under it; spec §7.3). `reserve`: room
    /// kept at the detail line's trailing end (the bubble's time).
    static func row(_ item: FileItem, at origin: CGPoint, width: CGFloat, mine: Bool, style: ChatStyle, reserve: CGFloat = 0) -> FileRowLayout {
        let nameFont = nameFont(style), detailFont = detailFont(style)
        let textX = rowLead + circle + circleGap
        let textW = max(20, width - textX - rowTrail)
        let line = ceil(nameFont.lineHeight)
        let measured = (item.attachment.name as NSString).boundingRect(with: CGSize(width: textW, height: .greatestFiniteMagnitude),
                                                                       options: [.usesLineFragmentOrigin],
                                                                       attributes: [.font: nameFont], context: nil)
        let lines = measured.height > line * 1.5 ? 2 : 1
        let nameH = line * CGFloat(lines)
        let detailH = ceil(detailFont.lineHeight)
        let textH = nameH + 2 + detailH
        let contentH = max(circle, textH)
        let rowH = rowPadV + contentH + rowPadV
        let circleY = rowPadV + (contentH - circle) / 2
        let textY = rowPadV + (contentH - textH) / 2
        return FileRowLayout(item: item, frame: CGRect(x: origin.x, y: origin.y, width: width, height: ceil(rowH)),
                             circle: CGRect(x: rowLead, y: circleY, width: circle, height: circle),
                             name: CGRect(x: textX, y: textY, width: textW, height: nameH), nameLines: lines,
                             detail: CGRect(x: textX, y: textY + nameH + 2, width: max(0, textW - reserve), height: detailH),
                             mine: mine)
    }

    /// Rows stacked from `y` (4 pt apart) at `width`; the last one keeps `lastReserve` for the time.
    static func rows(_ items: [FileItem], x: CGFloat, y: CGFloat, width: CGFloat, mine: Bool, style: ChatStyle,
                     lastReserve: CGFloat = 0) -> (rows: [FileRowLayout], maxY: CGFloat) {
        var out: [FileRowLayout] = []
        var cursor = y
        for (i, item) in items.enumerated() {
            if i > 0 { cursor += rowGap }
            let r = row(item, at: CGPoint(x: x, y: cursor), width: width, mine: mine, style: style,
                        reserve: i == items.count - 1 ? lastReserve : 0)
            out.append(r)
            cursor = r.frame.maxY
        }
        return (out, cursor)
    }

    // MARK: Fingerprints

    static func hash(_ items: [MediaItem], _ files: [FileItem], into h: inout Hasher) {
        h.combine(items.count)
        for m in items {
            h.combine(m.attachment.kind)
            h.combine(m.attachment.source)
            h.combine(m.attachment.name)
            h.combine(m.attachment.pixelWidth)
            h.combine(m.attachment.pixelHeight)
            h.combine(m.generated)
            h.combine(m.rendering)
        }
        h.combine(files.count)
        for f in files {
            h.combine(f.attachment.kind)
            h.combine(f.attachment.source)
            h.combine(f.attachment.name)
            h.combine(f.detail)
        }
    }
}
