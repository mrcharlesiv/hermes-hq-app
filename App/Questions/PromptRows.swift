import UIKit

// The transcript's prompt rows (spec 1x §4.2, §4.4): the approval card at the newest end, and the clarify note in
// place of the running clarify tool part (asked → sent answers → settled Q&A). Pure value types, built and measured
// on any thread like every other row (ChatRow.swift, TextLayout.swift: hooks marked [questions]).

// MARK: - Rows

/// What the chat screen hands the row builder (`ChatRowBuilder.Input.prompts`).
nonisolated struct PromptRowsInput: Sendable, Equatable {
    var approval: ApprovalCardRow?
    var clarifyNote: ClarifyNote?
}

nonisolated enum ClarifyNote: Sendable, Equatable, Hashable {
    /// "A question for you" / "N questions for you" + the first question.
    /// [groups] `asker`: in a room, the member who asks ("Ivy asks").
    case asked(count: Int, first: String, asker: String? = nil)
    case undelivered
    case sent([SentClarifyRow])
}

nonisolated struct ApprovalCardRow: Sendable, Equatable, Hashable {
    var id: String
    var stackExpired: Bool                 // "Approval expired" (every approval in the stack expired)
    var command: String
    var description: String
    var showsDescription: Bool
    var position: Int
    var total: Int
    var allowSession: Bool
    var allowAlways: Bool
    var expired: Bool
    var answering: ApprovalChoice?
    var leaving: Bool
    var clockKey: String
    var firstSeen: Date
    /// [groups] In a room: the member whose turn asks ("Ivy wants to run: …" over the card).
    var asker: String? = nil
    /// The chat's bot, for "Ask Ivy to try again" (nil: "the bot").
    var botName: String? = nil
}

nonisolated struct PromptRow: Sendable {
    enum Kind: Sendable {
        case approval(ApprovalCardRow)
        case note(ClarifyNote)
        case settled([ClarifyQA])
        /// [drafts] A bot's draft for review: its text, Send, Edit and Don't Send (HermesKit/Drafts/DraftCards.swift).
        case draft(DraftCardRow)
    }
    var kind: Kind
}

nonisolated enum PromptRows {
    /// The message id of rows drawn after the newest message (ChatRowModel rebuilds them with the newest end).
    static let tailMessageId = "prompts"
    static let commandClampLines = 8

    /// The rows after the newest message: the approval card, and the question note when no running clarify part
    /// holds it (a reopened chat).
    static func tail(_ input: ChatRowBuilder.Input) -> [ChatRow] {
        guard let prompts = input.prompts else { return [] }
        var rows: [ChatRow] = []
        if let note = prompts.clarifyNote, runningClarifyId(input.messages) == nil {
            rows.append(row(id: "\(tailMessageId)|note", messageId: tailMessageId, kind: .note(note), scope: input.scope))
        }
        if let approval = prompts.approval {
            rows.append(row(id: "\(tailMessageId)|approval", messageId: tailMessageId, kind: .approval(approval), scope: input.scope))
        }
        return rows
    }

    /// A clarify tool part's row: the note while it runs (and a note exists), the settled card once its result has
    /// `responses`, else nil (the generic tool row).
    static func clarifyRow(_ call: ToolCall, message: ChatMessage, input: ChatRowBuilder.Input) -> ChatRow? {
        guard call.name == "clarify" else { return nil }
        let id = "\(message.id)|q\(call.id)"
        if call.state == .running {
            guard let note = input.prompts?.clarifyNote, runningClarifyId(input.messages) == call.id else { return nil }
            return row(id: id, messageId: message.id, kind: .note(note), scope: input.scope)
        }
        guard let rows = ClarifySettled.rows(fromSummary: call.summary), !rows.isEmpty else { return nil }
        return row(id: id, messageId: message.id, kind: .settled(rows), scope: input.scope)
    }

    /// The newest running clarify tool part of the last few messages (the live turn's).
    static func runningClarifyId(_ messages: [ChatMessage]) -> String? {
        for m in messages.suffix(3).reversed() where m.role == .assistant {
            for part in m.parts.reversed() {
                if case .tool(let c) = part, c.name == "clarify", c.state == .running { return c.id }
            }
        }
        return nil
    }

    private static func row(id: String, messageId: String, kind: PromptRow.Kind, scope: String) -> ChatRow {
        var h = Hasher()
        switch kind {
        case .approval(let a): h.combine(0); h.combine(a)
        case .note(let n): h.combine(1); h.combine(n)
        case .settled(let rows): h.combine(2); h.combine(rows)
        case .draft(let d): h.combine(3); h.combine(d)
        }
        return ChatRow(id: id, messageId: messageId, scope: scope, fingerprint: h.finalize(), kind: .prompt(PromptRow(kind: kind)),
                       gapAbove: ChatMetrics.turnGap, variant: 0)
    }
}

// MARK: - Layout

nonisolated enum ApprovalButton: Sendable, Hashable { case reject, dismiss, more, session, always, run }

nonisolated struct PromptPlacedText: @unchecked Sendable {
    var text: TextKitLayout
    var frame: CGRect
}

nonisolated struct ApprovalCardLayout: @unchecked Sendable {
    var iconFrame: CGRect
    var expiryFrame: CGRect
    var expiryFont: UIFont
    /// At large text sizes the countdown takes its own line under "Command" (leading-aligned).
    var expiryLeading: Bool
    var showAllFrame: CGRect?
    var buttons: [(ApprovalButton, CGRect)]
    var buttonFont: UIFont
    var stacked: Bool
    /// The inset panel the command sits on, in the row's coordinates (as a draft card's words).
    var paper: CGRect? = nil
}

/// A symbol on a question card: the header's glyph, or the mark beside an answer.
nonisolated struct PromptSymbol: Sendable, Equatable {
    var frame: CGRect
    var name: String
    var style: Style
    /// `header` label-2; `picked` the dock's picked mark (tint disc, white check); `blank` label-3; `dim` a grey
    /// disc with a white glyph (a card's header mark when nothing was chosen).
    enum Style: Sendable { case header, picked, blank, dim }
}

nonisolated struct PromptRowLayout: @unchecked Sendable {
    /// The card (a reply bubble's fill, no edge) in row coordinates; nil for no card.
    var cardFrame: CGRect?
    var texts: [PromptPlacedText]
    var approval: ApprovalCardLayout?
    /// The question card's glyphs and answer marks, and the hairlines between its questions.
    var symbols: [PromptSymbol] = []
    var rules: [CGRect] = []
    /// [drafts] The draft card's Show All line and buttons.
    var draft: DraftCardLayout? = nil
    /// VoiceOver's reading of the whole card.
    var accessibility: String
}

nonisolated enum PromptFonts {
    private static func traits(_ c: UIContentSizeCategory) -> UITraitCollection { UITraitCollection(preferredContentSizeCategory: c) }

    static func font(_ style: UIFont.TextStyle, _ category: UIContentSizeCategory, weight: UIFont.Weight? = nil,
                     cap: CGFloat? = nil) -> UIFont {
        let base = HQFont.preferred(style, compatibleWith: traits(category))
        let size = cap.map { min($0, base.pointSize) } ?? base.pointSize
        if let weight { return HQFont.face(ofSize: size, weight: weight) }
        return size == base.pointSize ? base : base.withSize(size)
    }

    static func italic(_ style: UIFont.TextStyle, _ category: UIContentSizeCategory) -> UIFont {
        let f = font(style, category)
        guard let d = f.fontDescriptor.withSymbolicTraits(.traitItalic) else { return f }
        return UIFont(descriptor: d, size: f.pointSize)
    }

    static func mono(_ category: UIContentSizeCategory) -> UIFont {
        UIFontMetrics(forTextStyle: .footnote).scaledFont(for: HQFont.mono(ofSize: 13, weight: .regular),
                                                          compatibleWith: traits(category))
    }

    static func tabular(_ style: UIFont.TextStyle, _ category: UIContentSizeCategory, cap: CGFloat? = nil) -> UIFont {
        let f = font(style, category, cap: cap)
        return HQFont.monoDigitFace(ofSize: f.pointSize, weight: .regular)
    }

    /// Button titles: Subheadline semibold, capped at 22 (spec 1x §4.2).
    static func button(_ category: UIContentSizeCategory) -> UIFont { font(.subheadline, category, weight: .semibold, cap: 22) }
}

nonisolated enum PromptLayout {
    static let cardSide: CGFloat = 16
    static let headerGap: CGFloat = 8

    static func make(_ prompt: PromptRow, row: ChatRow, width: CGFloat, style: ChatStyle) -> RowLayout {
        switch prompt.kind {
        case .approval(let a): return approval(a, gap: row.gapAbove, width: width, category: style.category)
        case .note(let n): return note(n, gap: row.gapAbove, width: width, category: style.category)
        case .settled(let rows): return settled(rows, gap: row.gapAbove, width: width, category: style.category)
        case .draft(let d): return draft(d, gap: row.gapAbove, width: width, category: style.category)
        }
    }

    static func text(_ string: String, _ font: UIFont, _ color: UIColor, wrapAnywhere: Bool = false,
                     align: NSTextAlignment = .natural) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = wrapAnywhere ? .byCharWrapping : .byWordWrapping
        p.alignment = align
        return NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p])
    }

    /// Characters per line `bounded` keeps: more than any phone line of the card's text holds at the smallest size.
    static let boundedLineChars = 300

    /// At most `maxLines` newline-separated lines of at most `boundedLineChars` characters each: all that can show in
    /// `maxLines` laid-out lines. An approval command is unbounded (a heredoc runs to tens of KB) and its row is laid out
    /// on the main thread, so only this much is ever measured. `cut`: something was left out.
    static func bounded(_ string: String, maxLines: Int) -> (text: String, cut: Bool) {
        guard maxLines > 0 else { return (string, false) }
        var out = ""
        var lines = 0
        var index = string.startIndex
        while index < string.endIndex, lines < maxLines {
            let lineEnd = string[index...].firstIndex(where: \.isNewline) ?? string.endIndex
            let line = string[index..<lineEnd]
            let kept = line.prefix(boundedLineChars)
            if lines > 0 { out += "\n" }
            out += kept
            lines += 1
            if kept.endIndex < line.endIndex { return (out, true) }
            guard lineEnd < string.endIndex else { return (out, false) }
            index = string.index(after: lineEnd)
        }
        return (out, index < string.endIndex)
    }

    /// Lays `string` out; past `maxLines` it is cut at the end of that line. Returns the layout and whether it was cut.
    /// Only the `bounded` head of a long string is laid out.
    static func clamped(_ attributed: NSAttributedString, width: CGFloat, maxLines: Int) -> (TextKitLayout, Bool) {
        guard maxLines > 0, attributed.length > 0 else { return (TextKitLayout(attributed, width: width), false) }
        let attrs = attributed.attributes(at: 0, effectiveRange: nil)
        let (head, preCut) = bounded(attributed.string, maxLines: maxLines)
        let source = preCut ? NSAttributedString(string: head, attributes: attrs) : attributed
        let full = TextKitLayout(source, width: width)
        var lines = 0
        var endGlyph = 0
        let glyphs = full.manager.glyphRange(for: full.container)
        full.manager.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, range, stop in
            lines += 1
            endGlyph = NSMaxRange(range)
            if lines == maxLines { stop.pointee = true }
        }
        let overflow = lines == maxLines && endGlyph < glyphs.length
        guard overflow || preCut else { return (full, false) }
        var cut = head
        if overflow {
            let endChar = full.manager.characterIndexForGlyph(at: endGlyph)
            cut = source.attributedSubstring(from: NSRange(location: 0, length: endChar)).string
        }
        while cut.last?.isNewline == true { cut.removeLast() }
        let shortened = NSAttributedString(string: cut + "…", attributes: attrs)
        var short = TextKitLayout(shortened, width: width)
        // The ellipsis can push the last line over: drop characters until it fits in `maxLines`.
        var trimmed = cut
        while lineCount(short) > maxLines, !trimmed.isEmpty {
            trimmed.removeLast()
            short = TextKitLayout(NSAttributedString(string: trimmed + "…", attributes: attrs), width: width)
        }
        return (short, true)
    }

    static func lineCount(_ layout: TextKitLayout) -> Int {
        var lines = 0
        layout.manager.enumerateLineFragments(forGlyphRange: layout.manager.glyphRange(for: layout.container)) { _, _, _, _, _ in lines += 1 }
        return lines
    }

    // MARK: Approval card (§4.2)

    static func approvalTitle(_ a: ApprovalCardRow) -> String {
        if a.stackExpired { return "Approval expired" }
        // [groups] A room names the member whose turn waits (docs/spec/3x-groups.md §7.10).
        if let asker = a.asker, !asker.isEmpty {
            let first = a.command.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            if first.isEmpty { return "\(asker) needs your approval" }
            return "\(asker) wants to run: \(first.count > 60 ? String(first.prefix(60)) + "…" : first)"
        }
        return "Approval needed"
    }

    /// Under an expired card: whom to ask names the bot (or, in a room, the member whose turn asked).
    static func expiredNote(_ a: ApprovalCardRow) -> String {
        let who = [a.asker, a.botName].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        return "This request expired. Ask \(who ?? "the bot") to try again."
    }

    static func buttonTitle(_ button: ApprovalButton) -> String {
        switch button {
        case .reject: "Reject"
        case .dismiss: "Dismiss"
        case .more: "More…"
        case .session: "Allow for This Chat"
        case .always: "Always Allow…"
        case .run: "Run"
        }
    }

    static func buttons(_ a: ApprovalCardRow) -> [ApprovalButton] {
        if a.expired { return [.dismiss] }
        var out: [ApprovalButton] = [.reject]
        if a.allowSession && a.allowAlways { out.append(.more) }
        else if a.allowSession { out.append(.session) }
        else if a.allowAlways { out.append(.always) }
        out.append(.run)
        return out
    }

    static func approval(_ a: ApprovalCardRow, gap: CGFloat, width: CGFloat, category: UIContentSizeCategory) -> RowLayout {
        let side = cardSide
        let cardW = max(120, width - 2 * side)
        let innerX = notePadH
        let innerW = cardW - 2 * innerX
        var texts: [PromptPlacedText] = []
        let cardTop = gap + 6

        // Every card's header: a round terminal mark (grey once expired) and "Approval needed".
        let head = noteHeader(approvalTitle(a), glyph: "apple.terminal.circle.fill", dim: a.expired, x: side + innerX, y: cardTop + notePadV,
                              width: innerW, category: category)
        texts.append(head.text)

        // The line under it: "Command" / "Command details", "1 / 2", the expiry (trailing, updated in place).
        var cy: CGFloat = head.maxY - cardTop + 10
        let footnote = PromptFonts.font(.footnote, category)
        // The header line is meta: capped at 24 pt so "Command" and the countdown stay readable at AX sizes.
        let meta = PromptFonts.font(.footnote, category, cap: 24)
        let lineH = ceil(meta.lineHeight)
        let label = TextKitLayout(text(a.showsDescription ? "Command details" : "Command", meta, ChatPalette.label2), width: innerW)
        let labelFrame = CGRect(x: innerX, y: cy + (lineH - label.size.height) / 2, width: label.size.width, height: label.size.height)
        texts.append(PromptPlacedText(text: label, frame: labelFrame.offsetBy(dx: side, dy: cardTop)))
        var trailing = innerX + innerW
        let expiryFont = PromptFonts.tabular(.footnote, category, cap: 24)
        let expiryW = ceil(("Expires within 99 min" as NSString).size(withAttributes: [.font: expiryFont]).width)
        let pos = a.total > 1
            ? TextKitLayout(text("\(a.position) / \(a.total)", PromptFonts.tabular(.caption2, category), ChatPalette.label3), width: nil) : nil
        let posW = pos.map { $0.size.width + 8 } ?? 0
        // Everything on one line when it fits; otherwise the countdown (and "1 / 2") go on the next line.
        let oneLine = labelFrame.maxX + 8 + posW + expiryW <= innerX + innerW
        var expiryFrame: CGRect
        if oneLine {
            expiryFrame = CGRect(x: trailing - expiryW, y: cy, width: expiryW, height: lineH)
            trailing = expiryFrame.minX - 8
        } else {
            cy += max(lineH, label.size.height) + 2
            expiryFrame = CGRect(x: innerX, y: cy, width: innerW - posW, height: lineH)
        }
        if let pos {
            let frame = CGRect(x: trailing - pos.size.width, y: cy + (lineH - pos.size.height) / 2, width: pos.size.width, height: pos.size.height)
            texts.append(PromptPlacedText(text: pos, frame: frame.offsetBy(dx: side, dy: cardTop)))
        }
        cy += lineH + 8

        // The command (monospaced, ≤ 8 lines, wrapping anywhere) or the description, on an inset panel.
        let details = (a.showsDescription ? a.description : a.command).trimmingCharacters(in: .whitespacesAndNewlines)
        var showAllFrame: CGRect?
        var paper: CGRect?
        if !details.isEmpty {
            let pad: CGFloat = 12, wordsX = innerX + pad, wordsW = innerW - 2 * pad
            let paperTop = cy
            cy += pad
            let font = a.showsDescription ? footnote : PromptFonts.mono(category)
            let (body, cut) = clamped(text(details, font, ChatPalette.label, wrapAnywhere: true), width: wordsW, maxLines: PromptRows.commandClampLines)
            texts.append(PromptPlacedText(text: body, frame: CGRect(x: wordsX, y: cy, width: wordsW, height: body.size.height).offsetBy(dx: side, dy: cardTop)))
            cy += body.size.height
            if cut {
                let more = TextKitLayout(text("Show All", footnote, ChatPalette.tintText), width: nil)
                let frame = CGRect(x: wordsX, y: cy + 4, width: more.size.width, height: more.size.height)
                texts.append(PromptPlacedText(text: more, frame: frame.offsetBy(dx: side, dy: cardTop)))
                showAllFrame = frame.insetBy(dx: -8, dy: -(44 - frame.height) / 2).offsetBy(dx: side, dy: cardTop)
                cy = frame.maxY
            }
            cy += pad
            paper = CGRect(x: innerX, y: paperTop, width: innerW, height: cy - paperTop).offsetBy(dx: side, dy: cardTop)
        }
        // The reason under a shown command.
        let reason = a.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !a.showsDescription && !reason.isEmpty {
            let r = TextKitLayout(text(reason, footnote, ChatPalette.label2), width: innerW)
            texts.append(PromptPlacedText(text: r, frame: CGRect(x: innerX, y: cy + 8, width: innerW, height: r.size.height).offsetBy(dx: side, dy: cardTop)))
            cy += 8 + r.size.height
        }
        if a.expired {
            let e = TextKitLayout(text(expiredNote(a), footnote, ChatPalette.label2), width: innerW)
            texts.append(PromptPlacedText(text: e, frame: CGRect(x: innerX, y: cy + 6, width: innerW, height: e.size.height).offsetBy(dx: side, dy: cardTop)))
            cy += 6 + e.size.height
        }

        // Actions: one trailing row, or full-width stacked (Run first) at accessibility sizes or when they don't fit.
        let font = PromptFonts.button(category)
        let order = buttons(a)
        let h = max(44, ceil(font.lineHeight) + 16)
        func titleWidth(_ b: ApprovalButton) -> CGFloat {
            let titleW = ceil((buttonTitle(b) as NSString).size(withAttributes: [.font: font]).width)
            // Insets 14 + 14, a little slack for the configuration's own rounding, the chevron and its padding.
            return titleW + 32 + (b == .more ? 8 + ceil(font.pointSize * 1.05) : 0)
        }
        let widths = order.map(titleWidth)
        let rowW = widths.reduce(0, +) + CGFloat(max(0, order.count - 1)) * 8
        let stacked = category.isAccessibilityCategory || rowW > innerW
        cy += 12
        var placed: [(ApprovalButton, CGRect)] = []
        if stacked {
            // Run first, then the extra, then Reject (phone-fe-convo.css:534-536).
            let stackOrder = order.reversed()
            for b in stackOrder {
                placed.append((b, CGRect(x: innerX, y: cy, width: innerW, height: h)))
                cy += h + 8
            }
            cy -= 8
        } else {
            var x = innerX + innerW
            for (b, w) in zip(order, widths).reversed() {
                x -= w
                placed.append((b, CGRect(x: x, y: cy, width: w, height: h)))
                x -= 8
            }
            cy += h
        }
        cy += 12
        let card = CGRect(x: side, y: cardTop, width: cardW, height: ceil(cy))
        let buttonsInRow = placed.map { ($0.0, $0.1.offsetBy(dx: side, dy: cardTop)) }
        // 8 pt under the card: at the newest end its buttons sit 16 pt above the composer (§4.2 jump target).
        let height = ceil(card.maxY + 8)
        let spoken = [a.asker == nil ? "Approval needed" : approvalTitle(a), a.showsDescription ? "Command details: \(details)" : "Command: \(details)",
                      (!a.showsDescription && !reason.isEmpty) ? reason : nil,
                      a.expired ? expiredNote(a) : nil].compactMap { $0 }.joined(separator: ". ")
        let layout = PromptRowLayout(cardFrame: card, texts: texts,
                                     approval: ApprovalCardLayout(iconFrame: .zero,
                                                                  expiryFrame: expiryFrame.offsetBy(dx: side, dy: cardTop),
                                                                  expiryFont: expiryFont, expiryLeading: !oneLine,
                                                                  showAllFrame: showAllFrame,
                                                                  buttons: buttonsInRow, buttonFont: font, stacked: stacked, paper: paper),
                                     symbols: [head.symbol], accessibility: spoken)
        return RowLayout(height: height, content: .prompt(layout))
    }

    // MARK: Clarify note and settled card (§4.4)

    static func note(_ note: ClarifyNote, gap: CGFloat, width: CGFloat, category: UIContentSizeCategory) -> RowLayout {
        switch note {
        case .asked(let count, let first, let asker):
            var title = count > 1 ? "\(count) questions for you" : "A question for you"
            if let asker, !asker.isEmpty { title = count > 1 ? "\(asker) has \(count) questions for you" : "\(asker) asks" }   // [groups]
            return noteCard(title: title, glyph: "questionmark.circle.fill", detail: first, detailColor: ChatPalette.label,
                            gap: gap, width: width, category: category)
        case .undelivered:
            return noteCard(title: "A question for you", glyph: "exclamationmark.circle.fill",
                            detail: "This question didn’t reach the app, so it can’t be answered here. Press Stop to end the turn, then reply in chat.",
                            detailColor: ChatPalette.label2, gap: gap, width: width, category: category, detailLines: 0)
        case .sent(let rows):
            return qa(rows.map { ($0.question, $0.answer.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? "", $0.answer == nil) },
                      gap: gap, width: width, category: category)
        }
    }

    static func settled(_ rows: [ClarifyQA], gap: CGFloat, width: CGFloat, category: UIContentSizeCategory) -> RowLayout {
        qa(rows.map { ($0.question, $0.answer.trimmingCharacters(in: .whitespacesAndNewlines), $0.unanswered) },
           gap: gap, width: width, category: category)
    }

    // The chat's cards (owner 2026-11-09: an outline on the page colour looked bare, and every card of this kind is to
    // look the same): a reply bubble's fill with no edge, a header of a round mark and a semibold title, then the
    // content. Asked, sent and settled share it, so the card keeps its place and look while it changes state; the
    // draft card and the approval card wear the same shell.
    private static let notePadH: CGFloat = 14, notePadV: CGFloat = 12, noteHeaderGap: CGFloat = 8

    /// Every card's header: a round mark (`glyph` is a ".circle.fill" symbol; tint, or grey when `dim`) and the title
    /// in Subheadline semibold (capped at 26 pt), at `y`.
    static func noteHeader(_ title: String, glyph: String, dim: Bool = false, x: CGFloat, y: CGFloat, width: CGFloat,
                           category: UIContentSizeCategory) -> (text: PromptPlacedText, symbol: PromptSymbol, maxY: CGFloat) {
        let font = PromptFonts.font(.subheadline, category, weight: .semibold, cap: 26)
        let size = ceil(min(34, max(26, font.pointSize * 1.7)))
        let textX = x + size + 8
        let t = TextKitLayout(text(title, font, ChatPalette.label), width: width - (textX - x))
        let symbol = PromptSymbol(frame: CGRect(x: x, y: y, width: size, height: size), name: glyph, style: dim ? .dim : .picked)
        let frame = CGRect(x: textX, y: y + max(0, (size - t.size.height) / 2), width: t.size.width, height: t.size.height)
        return (PromptPlacedText(text: t, frame: frame), symbol, max(symbol.frame.maxY, frame.maxY))
    }

    private static func noteCard(title: String, glyph: String, detail: String, detailColor: UIColor, gap: CGFloat, width: CGFloat,
                                 category: UIContentSizeCategory, detailLines: Int = 2) -> RowLayout {
        let side = cardSide
        let cardW = max(120, width - 2 * side), innerW = cardW - 2 * notePadH
        let top = gap + 6, x = side + notePadH
        let head = noteHeader(title, glyph: glyph, x: x, y: top + notePadV, width: innerW, category: category)
        let (d, _) = clamped(text(detail, PromptFonts.font(.subheadline, category), detailColor), width: innerW, maxLines: detailLines)
        let dFrame = CGRect(x: x, y: head.maxY + noteHeaderGap, width: innerW, height: d.size.height)
        let card = CGRect(x: side, y: top, width: cardW, height: ceil(dFrame.maxY + notePadV - top))
        return RowLayout(height: ceil(card.maxY + 6), content: .prompt(PromptRowLayout(
            cardFrame: card, texts: [head.text, PromptPlacedText(text: d, frame: dFrame)], approval: nil,
            symbols: [head.symbol], accessibility: "\(title). \(detail)")))
    }

    /// The header for the answers: "Your answer(s)", or, when none was given, "Question skipped" / "N questions skipped".
    static func answersTitle(_ rows: [(question: String, answer: String, unanswered: Bool)]) -> (title: String, glyph: String) {
        if !rows.isEmpty, rows.allSatisfy({ $0.answer.isEmpty }) {
            return (rows.count == 1 ? "Question skipped" : "\(rows.count) questions skipped", "minus.circle.fill")
        }
        return (rows.count == 1 ? "Your answer" : "Your answers", "questionmark.circle.fill")
    }

    /// Each question in Subheadline label-2, its answer under it in Body semibold beside the dock's picked mark; a blank
    /// answer reads "Skipped" or "No answer" in italic label-3 beside a hollow mark. Hairlines between the questions.
    private static func qa(_ rows: [(question: String, answer: String, unanswered: Bool)], gap: CGFloat, width: CGFloat,
                           category: UIContentSizeCategory) -> RowLayout {
        let side = cardSide
        let cardW = max(120, width - 2 * side), innerW = cardW - 2 * notePadH
        let top = gap + 6, x = side + notePadH
        let (title, glyph) = answersTitle(rows)
        let head = noteHeader(title, glyph: glyph, dim: glyph.hasPrefix("minus"), x: x, y: top + notePadV, width: innerW, category: category)
        var texts = [head.text]
        var symbols = [head.symbol]
        var rules: [CGRect] = []
        var spoken: [String] = []
        let answerFont = PromptFonts.font(.body, category, weight: .semibold)
        let blankFont = PromptFonts.italic(.body, category)
        let mark = ceil(min(28, max(18, answerFont.pointSize * 1.06)))
        let answerX = x + mark + 8
        var y = head.maxY + noteHeaderGap + 2
        for (i, row) in rows.enumerated() {
            if i > 0 {
                y += 12
                rules.append(CGRect(x: x, y: y, width: innerW, height: 0))
                y += 12
            }
            let q = TextKitLayout(text(row.question, PromptFonts.font(.subheadline, category), ChatPalette.label2), width: innerW)
            texts.append(PromptPlacedText(text: q, frame: CGRect(x: x, y: y, width: innerW, height: q.size.height)))
            y += q.size.height + 6
            let blank = row.answer.isEmpty
            let words = blank ? (row.unanswered ? "No answer" : "Skipped") : row.answer
            let font = blank ? blankFont : answerFont
            let a = TextKitLayout(text(words, font, blank ? ChatPalette.label3 : ChatPalette.label), width: innerW - (answerX - x))
            let lineH = ceil(font.lineHeight)
            let first = max(lineH, mark)
            texts.append(PromptPlacedText(text: a, frame: CGRect(x: answerX, y: y + (first - lineH) / 2, width: a.size.width, height: a.size.height)))
            symbols.append(PromptSymbol(frame: CGRect(x: x, y: y + (first - mark) / 2, width: mark, height: mark),
                                        name: blank ? "minus.circle" : "checkmark.circle.fill", style: blank ? .blank : .picked))
            y += max(a.size.height + (first - lineH) / 2, first)
            spoken.append("\(row.question): \(words)")
        }
        let card = CGRect(x: side, y: top, width: cardW, height: ceil(y + notePadV - top))
        return RowLayout(height: ceil(card.maxY + 6), content: .prompt(PromptRowLayout(
            cardFrame: card, texts: texts, approval: nil, symbols: symbols, rules: rules,
            accessibility: ([title] + spoken).joined(separator: ". "))))
    }
}

// MARK: - Draft card ([drafts])

/// What the chat screen hands the row builder about its draft cards (`ChatRowBuilder.Input.drafts`).
nonisolated struct DraftRowsInput: Sendable, Equatable {
    /// Draft id → your answer, read from the chat's own messages (`DraftCards.answers`).
    var answers: [String: DraftCards.Answer] = [:]
    /// Draft id → the words you changed it to, not sent yet.
    var edits: [String: String] = [:]
    /// The draft whose words are in the message field.
    var editing: String? = nil
}

nonisolated enum DraftButton: Sendable, Hashable { case skip, edit, send }

nonisolated struct DraftCardRow: Sendable, Equatable, Hashable {
    enum State: Sendable, Hashable { case waiting, sent, skipped }
    var draft: DraftCards.Draft
    var rowId: String
    var messageId: String
    /// The words the card shows: what was sent, your edit, or the bot's draft.
    var body: String
    /// `body` isn't the bot's draft any more.
    var edited: Bool
    var state: State
    /// Its words are in the message field (the buttons wait).
    var editing: Bool
    /// Show All was tapped.
    var expanded: Bool
}

nonisolated struct DraftCardLayout: @unchecked Sendable {
    var showAllFrame: CGRect?
    var showAllTitle: String
    var buttons: [(DraftButton, CGRect)]
    var buttonFont: UIFont
    var stacked: Bool
    /// The inset panel the words sit on (a field you can change), in the row's coordinates.
    var paper: CGRect
    /// "Show Conversation (3)" / "Show Whole Message": its touch frame and title (it opens the sheet); nil when the
    /// bot gave no thread, or the preview already shows all of it.
    var threadFrame: CGRect? = nil
    var threadTitle = ""
    /// The bar down the side of the preview of the conversation.
    var quote: CGRect? = nil
}

nonisolated extension PromptRows {
    /// The card shows this many lines of a draft until Show All.
    static let draftClampLines = 14
    /// The preview of the conversation a draft answers: this many lines of words, over at most this many messages.
    static let threadPreviewLines = 6, threadPreviewMessages = 4

    /// A `draft_message` tool part's row; nil when the call can't be read as a draft (it draws as the step it is).
    static func draftRow(_ call: ToolCall, message: ChatMessage, input: ChatRowBuilder.Input) -> ChatRow? {
        guard let draft = DraftCards.draft(call) else { return nil }
        let id = "\(message.id)|draft\(call.id)"
        var card = DraftCardRow(draft: draft, rowId: id, messageId: message.id, body: draft.body, edited: false, state: .waiting,
                                editing: input.drafts.editing == draft.id, expanded: input.expanded.contains(id))
        switch input.drafts.answers[draft.id] {
        case .send(let body):
            card.state = .sent
            if let body { card.body = body }
        case .skip:
            card.state = .skipped
        case nil:
            if let edit = input.drafts.edits[draft.id] { card.body = edit }
        }
        card.edited = card.body != draft.body
        if card.state != .waiting { card.editing = false }
        return row(id: id, messageId: message.id, kind: .draft(card), scope: input.scope)
    }
}

/// The words of the conversation a draft answers, for its card's preview.
nonisolated enum DraftThreadText {
    /// Who wrote a message and when, on one line; empty when the bot gave neither.
    static func head(_ m: DraftCards.Message, category: UIContentSizeCategory) -> NSAttributedString {
        let out = NSMutableAttributedString()
        if !m.from.isEmpty { out.append(PromptLayout.text(m.from, PromptFonts.font(.footnote, category, weight: .semibold), ChatPalette.label)) }
        if !m.when.isEmpty { out.append(PromptLayout.text((m.from.isEmpty ? "" : "  ") + m.when, PromptFonts.font(.footnote, category), ChatPalette.label2)) }
        return out
    }

    /// A message's words for the preview: its lines run together, without an opening greeting ("Hi Alex,") or
    /// the lines it quotes from an earlier email ("> …"), so a few lines carry what it says. `whole` is false when
    /// that left anything out or changed its shape.
    static func flat(_ words: String) -> (words: String, whole: Bool) {
        var lines = words.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let all = lines.count
        let said = lines.filter { !$0.hasPrefix(">") }
        if !said.isEmpty { lines = said }
        if lines.count > 1, let first = lines.first, first.count <= 40, first.hasSuffix(",") { lines.removeFirst() }
        return (lines.joined(separator: " "), all <= 1)
    }
}

nonisolated extension PromptLayout {
    static func draftButtonTitle(_ button: DraftButton) -> String {
        switch button {
        case .skip: "Don’t Send"
        case .edit: "Edit"
        case .send: "Send"
        }
    }

    /// The line under an answered draft.
    static func draftStatus(_ d: DraftCardRow) -> String? {
        switch d.state {
        case .waiting: nil
        case .sent: d.edited ? "Approved to send, with your edits" : "Approved to send"
        case .skipped: "Not sent"
        }
    }

    /// The draft card: a filled card (a reply bubble's colour, no outline); a round tint mark for the kind of message
    /// beside "Email draft", then To, From and Subject as a letter's header, the words on an inset panel (clamped
    /// until Show All), then Don't Send, Edit and Send, or what you chose.
    static func draft(_ d: DraftCardRow, gap: CGFloat, width: CGFloat, category: UIContentSizeCategory) -> RowLayout {
        let side = cardSide
        let cardW = max(120, width - 2 * side), innerW = cardW - 2 * notePadH
        let top = gap + 6, x = side + notePadH
        let title = DraftCards.heading(d.draft) + (d.state == .waiting && d.edited ? " · Edited" : "")
        // A round tint mark for the kind of message, and the title in the label colour (every card's header).
        let head = noteHeader(title, glyph: DraftCards.glyph(d.draft), x: x, y: top + notePadV, width: innerW, category: category)
        var texts = [head.text]
        var symbols = [head.symbol]
        var spoken = [title]
        var y = head.maxY + 12
        // To, From, Subject: a letter's header, each on its own line with the labels in one column (at the largest
        // text sizes the label sits over its value).
        let fields = DraftCards.fields(d.draft)
        if !fields.isEmpty {
            let labelFont = PromptFonts.font(.subheadline, category)
            let over = category.isAccessibilityCategory
            let labelW = over ? 0 : ceil(fields.map { ($0.label as NSString).size(withAttributes: [.font: labelFont]).width }.max() ?? 0) + 12
            for field in fields {
                let label = TextKitLayout(text(field.label, labelFont, ChatPalette.label2), width: nil)
                texts.append(PromptPlacedText(text: label, frame: CGRect(x: x, y: y, width: label.size.width, height: label.size.height)))
                if over { y += label.size.height }
                let valueFont = PromptFonts.font(.subheadline, category, weight: field.strong ? .semibold : nil)
                let (value, _) = clamped(text(field.value, valueFont, ChatPalette.label, wrapAnywhere: !field.strong), width: innerW - labelW, maxLines: 2)
                texts.append(PromptPlacedText(text: value, frame: CGRect(x: x + labelW, y: y, width: innerW - labelW, height: value.size.height)))
                y += max(value.size.height, over ? 0 : label.size.height) + (over ? 8 : 5)
                spoken.append("\(field.label): \(field.value)")
            }
            y += over ? 8 : 11
        }
        // The conversation it answers: a short preview beside a bar (the message being answered, and the ones before
        // it while there is room), then a button that opens all of it in a sheet.
        var threadFrame: CGRect?, quote: CGRect?
        var threadTitle = ""
        let thread = d.draft.thread
        if !thread.isEmpty {
            let inset: CGFloat = 12, textW = innerW - inset
            var left = PromptRows.threadPreviewLines, whole = true
            var blocks: [(head: TextKitLayout?, words: TextKitLayout, message: DraftCards.Message)] = []
            for message in thread.reversed() {
                guard left > 0, blocks.count < PromptRows.threadPreviewMessages else { break }
                let flat = DraftThreadText.flat(message.text)
                let (words, wasCut) = clamped(text(flat.words, PromptFonts.font(.subheadline, category), ChatPalette.label), width: textW, maxLines: left)
                left -= max(1, lineCount(words))
                whole = whole && !wasCut && flat.whole
                let who = DraftThreadText.head(message, category: category)
                blocks.insert((who.length > 0 ? TextKitLayout(who, width: textW) : nil, words, message), at: 0)
            }
            let quoteTop = y
            for (i, block) in blocks.enumerated() {
                if i > 0 { y += 10 }
                if let head = block.head {
                    texts.append(PromptPlacedText(text: head, frame: CGRect(x: x + inset, y: y, width: textW, height: head.size.height)))
                    y += head.size.height + 2
                }
                texts.append(PromptPlacedText(text: block.words, frame: CGRect(x: x + inset, y: y, width: textW, height: block.words.size.height)))
                y += block.words.size.height
                spoken.append([block.message.from, block.message.when, block.words.text.string].filter { !$0.isEmpty }.joined(separator: ", "))
            }
            quote = CGRect(x: x, y: quoteTop, width: 3, height: y - quoteTop)
            if !whole || blocks.count < thread.count {
                y += 10
                threadTitle = DraftCards.threadTitle(d.draft)
                let link = TextKitLayout(text(threadTitle, PromptFonts.font(.subheadline, category, weight: .medium), ChatPalette.tintText), width: innerW)
                let frame = CGRect(x: x, y: y, width: link.size.width, height: link.size.height)
                texts.append(PromptPlacedText(text: link, frame: frame))
                threadFrame = frame.insetBy(dx: -8, dy: -max(0, (44 - frame.height) / 2))
                y = frame.maxY
            }
            y += 12
        }
        // The words sit on an inset panel, as a field you can change.
        let pad: CGFloat = 12
        let paperTop = y
        y += pad
        let wx = x + pad, wordsW = innerW - 2 * pad, outerX = x
        let bodyText = text(d.body, PromptFonts.font(.body, category), d.state == .skipped ? ChatPalette.label2 : ChatPalette.label)
        let (body, cut) = clamped(bodyText, width: wordsW, maxLines: d.expanded ? 0 : PromptRows.draftClampLines)
        texts.append(PromptPlacedText(text: body, frame: CGRect(x: wx, y: y, width: wordsW, height: body.size.height)))
        y += body.size.height
        spoken.append(d.body)
        var showAllFrame: CGRect?
        let showAllTitle = d.expanded ? "Show Less" : "Show All"
        if cut || d.expanded && lineCount(body) > PromptRows.draftClampLines {
            let more = TextKitLayout(text(showAllTitle, PromptFonts.font(.footnote, category), ChatPalette.tintText), width: nil)
            let frame = CGRect(x: wx, y: y + 4, width: more.size.width, height: more.size.height)
            texts.append(PromptPlacedText(text: more, frame: frame))
            showAllFrame = frame.insetBy(dx: -8, dy: -(44 - frame.height) / 2)
            y = frame.maxY
        }
        y += pad
        let paper = CGRect(x: outerX, y: paperTop, width: innerW, height: y - paperTop)
        return draftFoot(d, x: outerX, y: y, innerW: innerW, side: side, top: top, cardW: cardW, category: category, texts: texts, symbols: symbols,
                         spoken: spoken, showAllFrame: showAllFrame, showAllTitle: showAllTitle, paper: paper) { layout in
            layout.threadFrame = threadFrame; layout.threadTitle = threadTitle
            layout.quote = quote
        }
    }

    private static func draftFoot(_ d: DraftCardRow, x: CGFloat, y: CGFloat, innerW: CGFloat, side: CGFloat, top: CGFloat, cardW: CGFloat,
                                  category: UIContentSizeCategory, texts: [PromptPlacedText], symbols: [PromptSymbol],
                                  spoken: [String], showAllFrame: CGRect?, showAllTitle: String, paper: CGRect,
                                  thread: (inout DraftCardLayout) -> Void) -> RowLayout {
        var y = y, texts = texts, symbols = symbols, spoken = spoken
        var placed: [(DraftButton, CGRect)] = []
        let font = PromptFonts.button(category)
        var stacked = false
        if let status = draftStatus(d) {
            // Answered: what you chose, beside the question card's marks.
            let statusFont = PromptFonts.font(.footnote, category, weight: .semibold, cap: 24)
            let mark = ceil(min(24, max(15, statusFont.pointSize * 1.15)))
            let lineH = ceil(statusFont.lineHeight), first = max(lineH, mark)
            y += 10
            let s = TextKitLayout(text(status, statusFont, ChatPalette.label2), width: innerW - mark - 6)
            texts.append(PromptPlacedText(text: s, frame: CGRect(x: x + mark + 6, y: y + (first - lineH) / 2, width: s.size.width, height: s.size.height)))
            symbols.append(PromptSymbol(frame: CGRect(x: x, y: y + (first - mark) / 2, width: mark, height: mark),
                                        name: d.state == .sent ? "checkmark.circle.fill" : "minus.circle",
                                        style: d.state == .sent ? .picked : .blank))
            y += max(first, s.size.height + (first - lineH) / 2)
            spoken.append(status)
        } else {
            // Actions: one trailing row (Don't Send, Edit, Send), or full width stacked with Send first.
            let order: [DraftButton] = [.skip, .edit, .send]
            let h = max(44, ceil(font.lineHeight) + 16)
            let widths = order.map { ceil((draftButtonTitle($0) as NSString).size(withAttributes: [.font: font]).width) + 32 }
            let rowW = widths.reduce(0, +) + CGFloat(order.count - 1) * 8
            stacked = category.isAccessibilityCategory || rowW > innerW
            y += 12
            if stacked {
                for b in order.reversed() {
                    placed.append((b, CGRect(x: x, y: y, width: innerW, height: h)))
                    y += h + 8
                }
                y -= 8
            } else {
                var right = x + innerW
                for (b, w) in zip(order, widths).reversed() {
                    right -= w
                    placed.append((b, CGRect(x: right, y: y, width: w, height: h)))
                    right -= 8
                }
                y += h
            }
        }
        let card = CGRect(x: side, y: top, width: cardW, height: ceil(y + notePadV - top))
        var layout = PromptRowLayout(cardFrame: card, texts: texts, approval: nil, symbols: symbols, rules: [],
                                     accessibility: spoken.joined(separator: ". "))
        var draft = DraftCardLayout(showAllFrame: showAllFrame, showAllTitle: showAllTitle, buttons: placed, buttonFont: font, stacked: stacked,
                                    paper: paper)
        thread(&draft)
        layout.draft = draft
        return RowLayout(height: ceil(card.maxY + 6), content: .prompt(layout))
    }
}
