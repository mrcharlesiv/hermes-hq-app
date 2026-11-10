import UIKit

// Bubbles with photos and files (docs/spec/1x-attachments.md §7.3, §7.5, §7.7), Telegram's media bubble shapes in
// Hermes colours (A7): photos edge to edge at the top, clipped to the bubble's outline, then file rows, then the
// caption with the normal padding; a photo-only message is the photo itself (no fill, no tail) with its time in a
// dim capsule. Exact sizes from `MediaLayout`, measured off the main thread like every other row.

nonisolated enum AttachmentBubbleLayout {
    /// Space above a caption that follows media.
    static let captionGap: CGFloat = 6

    private static func timeAttr(_ time: Date?, mine: Bool, capsule: Bool, style: ChatStyle) -> (String?, CGSize) {
        guard let time, capsule || HQShape.showsTime(mine: mine) else { return (nil, .zero) }   // [desktoplook]
        let text = ChatRowBuilder.clock(time)
        let w = ceil((text as NSString).size(withAttributes: [.font: style.time]).width)
        return (text, CGSize(width: w, height: style.timeLineHeight))
    }

    /// Your bubble with attachments, or a generated-image card (a bot row whose only media is the card).
    static func bubble(_ b: BubbleRow, row: ChatRow, width: CGFloat, style: ChatStyle, keep: Bool) -> RowLayout {
        let mine = b.mine
        let generated = b.media.count == 1 ? b.media[0].generated : nil
        let maxBubble = generated != nil ? width - 2 * ChatMetrics.sideInset : TextLayout.maxBubbleWidth(mine: mine, width: width, style: style)
        let hasText = !b.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let mediaOnly = !b.media.isEmpty && b.files.isEmpty && !hasText
        let (timeText, timeSize) = timeAttr(b.time, mine: mine, capsule: mediaOnly, style: style)
        // A caption's time clear of a round corner (Theme › Bubble Corners). A file row's sits 14 pt or more up, clear
        // of any corner the slider makes.
        let timeShift = timeText == nil || !hasText ? 0 : ChatMetrics.timeShift(mine: mine, joinsBelow: b.joinsBelow, tail: b.tail)
        let reserve = timeText == nil ? 0 : timeSize.width + ChatMetrics.timeReserveGap + timeShift

        // Photos.
        var album = CGSize.zero
        var tiles: [(item: MediaItem, frame: CGRect)] = []
        // Two or more: a stack you swipe through (its top card, in the group). Alone it is the bubble, the card's corner
        // the bubble's; over a caption or files it sits in the bubble's fill, `stackInset` in from its edges.
        var stackCard: CGRect?
        let stackInset: CGFloat = mediaOnly ? 0 : MediaLayout.stackPadY
        if let generated {
            album = MediaLayout.generated(generated, column: maxBubble)
            tiles = [(b.media[0], CGRect(origin: .zero, size: album))]
        } else if b.media.count >= 2 {
            let laid = MediaLayout.stack(sizes: b.media.map { ($0.attachment.pixelWidth, $0.attachment.pixelHeight) },
                                         maxWidth: maxBubble - 2 * stackInset)
            let card = laid.card.offsetBy(dx: stackInset, dy: 0)
            album = CGSize(width: laid.size.width + 2 * stackInset, height: laid.size.height)
            stackCard = card
            tiles = b.media.map { ($0, card) }
        } else if !b.media.isEmpty {
            let laid = MediaLayout.frames(sizes: b.media.map { ($0.attachment.pixelWidth, $0.attachment.pixelHeight) }, maxWidth: maxBubble)
            album = laid.size
            tiles = zip(b.media, laid.frames).map { ($0, $1) }
        }

        // The caption's text, laid out once the bubble's width is known.
        let rendered = hasText ? TextLayout.rendered(b, row: row, style: style) : nil
        let padH = ChatMetrics.bubblePadH, padV = ChatMetrics.bubblePadV

        let filesNatural = b.files.map { MediaLayout.naturalRowWidth($0, style: style, reserve: hasText ? 0 : reserve) }.max() ?? 0
        var textNatural: CGFloat = 0
        if let rendered, case .text(let s)? = rendered.blocks.first {
            let laid = TextLayout.pieces(s, width: maxBubble - 2 * padH, keep: false)
            textNatural = max(laid.width, laid.lastLineMaxX + reserve) + 2 * padH
        }
        var bubbleW: CGFloat
        var fits = false
        if !b.media.isEmpty {
            bubbleW = album.width
            // A tall photo (a phone screenshot) comes out 150 wide; its caption or files would wrap in that sliver.
            // The bubble takes a normal photo's width instead and the whole photo sits centred on a blur of itself.
            let wide = floor(min(maxBubble, MediaLayout.singleMax))
            if generated == nil, tiles.count == 1, album.width < wide, max(filesNatural, textNatural) > album.width {
                album.width = wide
                tiles[0].frame.size.width = wide
                bubbleW = wide
                fits = true
            } else if stackCard != nil, album.width < wide, max(filesNatural, textNatural) > album.width {
                // A stack of tall screenshots: the caption gets a normal photo's width and the stack sits centred over it.
                bubbleW = wide
            }
        } else {
            bubbleW = min(maxBubble, max(filesNatural, textNatural, 200))
        }
        bubbleW = ceil(bubbleW)

        var y: CGFloat = 0
        var groups: [MediaGroupLayout] = []
        var stackX: CGFloat = 0
        if let stackCard {
            stackX = floor((ceil(bubbleW) - album.width) / 2)
            // Alone, the cards have the photo bubble's corner; in a bubble's fill, a smaller one inside it.
            let radius = mediaOnly ? ChatMetrics.bubbleRadius : max(HQShape.radius(4, .card), ChatMetrics.bubbleRadius - 4)
            groups.append(MediaGroupLayout(frame: CGRect(x: stackX, y: 0, width: album.width, height: album.height), radius: radius,
                                           tiles: tiles, stack: stackCard))
            y = album.height
        } else if !tiles.isEmpty {
            groups.append(MediaGroupLayout(frame: CGRect(x: 0, y: 0, width: album.width, height: album.height),
                                           radius: generated != nil ? ChatMetrics.bubbleRadius : nil, tiles: tiles, fits: fits))
            y = album.height
        }
        var rows: [FileRowLayout] = []
        if !b.files.isEmpty {
            y += b.media.isEmpty ? 2 : MediaLayout.rowGap
            let laid = MediaLayout.rows(b.files, x: 0, y: y, width: bubbleW, mine: mine, style: style, lastReserve: hasText ? 0 : reserve)
            rows = laid.rows
            y = laid.maxY + (hasText ? 0 : 2)
        }
        var placed: [PlacedBlock] = []
        var timeFrame = CGRect.zero
        var capsule: CGRect?
        if let rendered, case .text(let s)? = rendered.blocks.first {
            y += (b.media.isEmpty && b.files.isEmpty) ? padV : captionGap
            let maxText = bubbleW - 2 * padH
            let laid = TextLayout.pieces(s, width: maxText, keep: keep)
            var h = laid.height
            var w = laid.width
            if reserve > 0 {
                if laid.lastLineMaxX + reserve <= maxText { w = max(w, laid.lastLineMaxX + reserve) } else { h += style.bodyLineHeight }
            }
            placed.append(PlacedBlock(block: .text(s), frame: CGRect(x: padH, y: y, width: max(w, maxText), height: h),
                                      textFrame: CGRect(x: 0, y: 0, width: laid.width, height: laid.height),
                                      contentWidth: laid.width, contentHeight: laid.height, layoutWidth: maxText, pieces: laid.pieces,
                                      codeOpen: nil))
            y += h + padV
            timeFrame = CGRect(x: bubbleW - ChatMetrics.timeTrailing - timeShift - timeSize.width,
                               y: y - ChatMetrics.timeBottom - timeShift - timeSize.height, width: timeSize.width, height: timeSize.height)
        } else if mediaOnly {
            if timeText != nil && generated == nil {
                // A dim capsule at the bottom-trailing corner, 6 pt in: Caption 2 white on black 45 %, 4/7 pt padding.
                // Further in past a 12 pt corner (Theme › Bubble Corners), so the photo's curve never meets it.
                let capH = timeSize.height + 8
                // On a stack, the top card's corner (its own, never joined to the next bubble).
                let corner = stackCard != nil ? ChatMetrics.bubbleRadius : ChatMetrics.timeCorner(mine: mine, joinsBelow: b.joinsBelow, tail: false)
                let inset = 6 + ChatMetrics.timeShift(corner: corner, trailing: 6, bottom: 6, round: capH / 2)
                let right = stackCard.map { stackX + $0.maxX } ?? bubbleW
                let bottom = stackCard?.maxY ?? y
                let cap = CGRect(x: right - inset - (timeSize.width + 14), y: bottom - inset - capH,
                                 width: timeSize.width + 14, height: capH)
                capsule = cap
                timeFrame = CGRect(x: cap.minX + 7, y: cap.minY + 4, width: timeSize.width, height: timeSize.height)
            }
        } else if let last = rows.last {
            // Files only: the time on the last row's detail line, trailing.
            timeFrame = CGRect(x: bubbleW - ChatMetrics.timeTrailing - timeSize.width,
                               y: last.frame.minY + last.detail.maxY - timeSize.height, width: timeSize.width, height: timeSize.height)
        }
        let bubbleH = ceil(y)
        let gap = max(0, row.gapAbove)
        let x = mine ? width - ChatMetrics.sideInset - bubbleW : ChatMetrics.sideInset
        let shape = BubbleShape.Key(width: bubbleW, height: bubbleH, mine: mine, joinsAbove: b.joinsAbove, joinsBelow: b.joinsBelow,
                                    tail: mediaOnly ? false : b.tail)
        let copy = [rendered?.plainText, b.files.map(\.attachment.name).joined(separator: "\n")]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        var layout = BubbleLayout(frame: CGRect(x: x, y: gap, width: bubbleW, height: bubbleH), shape: shape, mine: mine, blocks: placed,
                                  timeText: generated != nil ? nil : timeText, timeFrame: timeFrame, dimmed: false, copyText: copy,
                                  showMoreFrame: nil)
        layout.mediaGroups = groups
        layout.fileRows = rows
        layout.mediaOnly = mediaOnly
        layout.timeCapsule = capsule
        return RowLayout(height: gap + bubbleH, content: .bubble(layout))
    }

    /// What a sent bubble with attachments lifts from the composer (row coordinates): its photos, file rows and
    /// caption together (`text`: the caption's box, if any).
    static func liftBox(_ b: BubbleLayout, text: CGRect?) -> CGRect? {
        var box = text ?? .null
        for g in b.mediaGroups { box = box.union(g.frame.offsetBy(dx: b.frame.minX, dy: b.frame.minY)) }
        for r in b.fileRows { box = box.union(r.frame.offsetBy(dx: b.frame.minX, dy: b.frame.minY)) }
        return box.isNull ? nil : box
    }

    /// A reply part whose blocks are images only (`MEDIA:` alone, `![alt](src)` alone): drawn like a photo-only bubble.
    /// A reply names a picture without its size: the size its first load learnt (`sizes`, by `sizeKey`), once there is one.
    private static func sized(_ a: MessageAttachment, _ sizes: [String: MediaPixelSize]) -> MessageAttachment {
        guard a.pixelWidth == nil || a.pixelHeight == nil, let key = a.sizeKey, let size = sizes[key] else { return a }
        var a = a
        a.pixelWidth = size.width
        a.pixelHeight = size.height
        return a
    }

    static func photoOnlyReply(_ rendered: RenderedMarkdown, _ b: BubbleRow, row: ChatRow, width: CGFloat, style: ChatStyle) -> RowLayout? {
        guard !rendered.blocks.isEmpty else { return nil }
        var refs: [MediaRef] = []
        for block in rendered.blocks {
            guard case .media(let r) = block, r.allSatisfy({ $0.kind == .image }) else { return nil }
            refs += r
        }
        guard !refs.isEmpty else { return nil }
        var photo = b
        photo.media = refs.map { MediaItem(attachment: sized($0.attachment, b.mediaSizes), index: -1, context: b.mediaContext, label: $0.label) }
        photo.text = ""
        // Albums and single photos stay within 260 pt (inside the 280 pt reply limit, spec §7.5).
        return bubble(photo, row: row, width: width, style: style, keep: false)
    }

    /// A `.media` block inside a reply bubble: photos as an album (≤ 280 wide, radius 12) then file rows across the
    /// content width (spec §7.5).
    /// A picture the gateway refused (`unavailable`, by path) is a file row with the reason: its name, never its path.
    static func mediaBlock(_ refs: [MediaRef], context: MediaContext?, maxText: CGFloat, mine: Bool, style: ChatStyle, reserve: CGFloat = 0,
                           unavailable: [String: String] = [:], sizes: [String: MediaPixelSize] = [:]) -> (size: CGSize, media: BlockMedia) {
        func refused(_ ref: MediaRef) -> String? { ref.attachment.gatewayPath.flatMap { unavailable[$0] } }
        let images = refs.filter { $0.kind == .image && refused($0) == nil }
        let others = refs.filter { $0.kind != .image || refused($0) != nil }
        var groups: [MediaGroupLayout] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        if images.count >= 2 {
            // Several pictures: a stack you swipe through, its card in line with the reply's text.
            let items = images.map { MediaItem(attachment: sized($0.attachment, sizes), index: -1, context: context, label: $0.label) }
            let laid = MediaLayout.stack(sizes: items.map { ($0.attachment.pixelWidth, $0.attachment.pixelHeight) },
                                         maxWidth: min(maxText, MediaLayout.replyMax))
            groups.append(MediaGroupLayout(frame: CGRect(origin: .zero, size: laid.size), radius: MediaLayout.replyRadius,
                                           tiles: items.map { ($0, laid.card) }, stack: laid.card))
            y = laid.size.height
            width = laid.size.width
        } else if !images.isEmpty {
            let items = images.map { MediaItem(attachment: sized($0.attachment, sizes), index: -1, context: context, label: $0.label) }
            let laid = MediaLayout.frames(sizes: items.map { ($0.attachment.pixelWidth, $0.attachment.pixelHeight) },
                                          maxWidth: min(maxText, MediaLayout.replyMax))
            groups.append(MediaGroupLayout(frame: CGRect(origin: .zero, size: laid.size), radius: MediaLayout.replyRadius,
                                           tiles: zip(items, laid.frames).map { ($0, $1) }))
            y = laid.size.height
            width = laid.size.width
        }
        var rows: [FileRowLayout] = []
        if !others.isEmpty {
            if y > 0 { y += 6 }
            let files = others.map { ref in
                FileItem(attachment: ref.attachment, index: -1, context: context, detail: refused(ref) ?? ChatMediaRows.detail(ref.attachment))
            }
            // As wide as the widest row's words (≥ 220 pt, ≤ the bubble), not always the whole bubble.
            let rowWidth = min(maxText, max(220, width, files.map { MediaLayout.naturalRowWidth($0, style: style, reserve: reserve) }.max() ?? 0))
            let laid = MediaLayout.rows(files, x: 0, y: y, width: rowWidth, mine: mine, style: style, lastReserve: reserve)
            rows = laid.rows
            y = laid.maxY
            width = max(width, rowWidth)
        }
        return (CGSize(width: width, height: ceil(y)), BlockMedia(groups: groups, rows: rows))
    }
}
