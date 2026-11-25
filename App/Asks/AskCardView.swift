import UIKit

// [asks] The ask-to-act card: a bot asks before it acts for you. Top to bottom: where it came from ("Slack · Dana
// Reyes · DM · 11:03 AM" beside the app's round mark), their words beside a bar, what they attached as chips, a link
// to the place, the question in bold, a button per choice (the first, the bot's pick, filled), a quiet "Something
// else…" and what the bot does next. Once answered, the buttons give way to "You answered: Yes". The card wears every
// chat card's shell (a reply bubble's fill, a round mark), so its words and marks are drawn by the prompt cell from
// `AskCardLayout`; the buttons, the links, the bar and the chips' outlines are this file's own view.

// MARK: - Layout

nonisolated struct AskCardGeometry: @unchecked Sendable {
    /// Each choice's button (its 0-based index), in the row's coordinates; none once answered.
    var buttons: [(Int, CGRect)]
    var titles: [String]
    var font: UIFont
    var stacked: Bool
    /// "Something else…" (its touch frame) and the link ("Open in Slack ↗"), when shown.
    var other: CGRect?
    var link: CGRect?
    var linkTitle: String
    /// The bar beside their words.
    var quote: CGRect?
    /// Each attachment's chip outline and the frame of its document mark.
    var chips: [(chip: CGRect, icon: CGRect)]
    /// The buttons wait (the strip for your own words, or the reply's Edit strip, is open).
    var disabled: Bool
    /// [asks v2] The choice you picked (its button stays filled, the others go outline); nil: the bot's pick is filled.
    var picked: Int? = nil
    /// [asks v2] The panel the ready reply sits on (a draft card's), its Send and Edit (a draft card's buttons, Send
    /// first when stacked) and Show All under a long one.
    var paper: CGRect? = nil
    var replyButtons: [(DraftButton, CGRect)] = []
    var replyStacked = false
    var showAll: CGRect? = nil
    var showAllTitle = ""
    /// [calm-chat] Single-surface left accent bar / receipt stem, subtle divider, and tap-to-expand toggle.
    var bodyBar: CGRect? = nil
    var bodyBarTint = false
    var footerDivider: CGRect? = nil
    var toggleFrame: CGRect? = nil
    var toggleLabel = ""
    var toggleExpanded = false
    var backingFrame: CGRect? = nil
}

nonisolated enum AskCardLayout {
    static let side: CGFloat = 16, padH: CGFloat = 14, padV: CGFloat = 12
    static let otherTitle = "Something else…"
    static let quoteLines = 6

    static func linkTitle(_ link: AskCards.Link) -> String { link.title + " ↗" }

    /// The source line: the app (or, without one, who wrote) in semibold, the rest quieter.
    static func source(_ ask: AskCards.Ask, category: UIContentSizeCategory) -> (NSAttributedString, String) {
        let strong = PromptFonts.font(.subheadline, category, weight: .semibold, cap: 26)
        let quiet = PromptFonts.font(.subheadline, category, cap: 26)
        var lead = ask.app, rest = [ask.from, ask.place, ask.when].filter { !$0.isEmpty }
        if lead.isEmpty, !rest.isEmpty { lead = rest.removeFirst() }
        if lead.isEmpty { lead = "A question for you" }
        let out = NSMutableAttributedString(attributedString: PromptLayout.text(lead, strong, ChatPalette.label))
        let tail = rest.joined(separator: " · ")
        if !tail.isEmpty { out.append(PromptLayout.text(" · " + tail, quiet, ChatPalette.label2)) }
        return (out, ([lead] + rest).joined(separator: ", "))
    }

    static func make(_ card: AskCardRow, gap: CGFloat, width: CGFloat, category: UIContentSizeCategory) -> RowLayout {
        if card.stale && card.answer == nil {
            return makeFolded(card, gap: gap, width: width, category: category)
        }
        if let answer = card.answer, !card.expanded {
            return makeReceipt(card, answer: answer, gap: gap, width: width, category: category)
        }
        let a = card.ask
        let cardW = PromptLayout.cardWidth(for: width), innerW = cardW - 2 * padH
        let top = max(0, gap) + 6, x = side + padH
        var texts: [PromptPlacedText] = [], symbols: [PromptSymbol] = [], spoken: [String] = []

        // The source line beside the app's round mark (every card's header).
        let headFont = PromptFonts.font(.subheadline, category, weight: .semibold, cap: 26)
        let mark = ceil(min(34, max(26, headFont.pointSize * 1.7)))
        let (sourceText, sourceSpoken) = source(a, category: category)
        let textX = x + mark + 8
        let chevW: CGFloat = card.answer != nil ? ceil(min(18, max(12, headFont.pointSize * 0.8))) : 0
        let sourceMaxW = max(60, x + innerW - textX - (chevW > 0 ? chevW + 8 : 0))
        let (s, _) = PromptLayout.clamped(sourceText, width: sourceMaxW, maxLines: 2)
        let markY = top + padV
        symbols.append(PromptSymbol(frame: CGRect(x: x, y: markY, width: mark, height: mark), name: AskCards.glyph(a), style: .picked))
        texts.append(PromptPlacedText(text: s, frame: CGRect(x: textX, y: markY + max(0, (mark - s.size.height) / 2), width: s.size.width, height: s.size.height)))
        if chevW > 0 {
            let firstH = max(mark, s.size.height)
            symbols.append(PromptSymbol(frame: CGRect(x: x + innerW - chevW, y: markY + ((firstH - chevW) / 2).rounded(), width: chevW, height: chevW),
                                        name: "chevron.up", style: .blank))
        }
        spoken.append(sourceSpoken)
        var y = max(markY + mark, markY + s.size.height)
        let headerBandH = max(44, y - top + padV)

        let body = PromptFonts.font(.subheadline, category)
        let small = PromptFonts.font(.footnote, category)

        // Their words, beside a bar.
        var quote: CGRect?
        if !a.quote.isEmpty {
            y += 10
            let inset: CGFloat = 12
            let (q, _) = PromptLayout.clamped(PromptLayout.text("“\(a.quote)”", body, ChatPalette.label), width: innerW - inset, maxLines: quoteLines)
            texts.append(PromptPlacedText(text: q, frame: CGRect(x: x + inset, y: y, width: innerW - inset, height: q.size.height)))
            quote = CGRect(x: x, y: y, width: 3, height: q.size.height)
            y += q.size.height
            spoken.append(a.quote)
        }

        // What they attached: a chip each, the name then the note, one line.
        var chips: [(CGRect, CGRect)] = []
        if !a.attachments.isEmpty {
            y += 10
            let chipFont = PromptFonts.font(.footnote, category, cap: 24)
            let nameFont = PromptFonts.font(.footnote, category, weight: .semibold, cap: 24)
            let lineH = ceil(chipFont.lineHeight)
            let icon = ceil(chipFont.pointSize * 1.05)
            let padX: CGFloat = 10, h = lineH + 8
            for (i, file) in a.attachments.enumerated() {
                if i > 0 { y += 6 }
                let words = NSMutableAttributedString(attributedString: PromptLayout.text(file.name, nameFont, ChatPalette.label))
                if !file.note.isEmpty { words.append(PromptLayout.text(" · " + file.note, chipFont, ChatPalette.label2)) }
                let room = innerW - 2 * padX - icon - 6
                let (t, _) = PromptLayout.clamped(words, width: room, maxLines: 1)
                let chipW = min(innerW, ceil(t.size.width) + 2 * padX + icon + 6)
                let chip = CGRect(x: x, y: y, width: chipW, height: h)
                let iconFrame = CGRect(x: x + padX, y: y + (h - icon) / 2, width: icon, height: icon)
                texts.append(PromptPlacedText(text: t, frame: CGRect(x: iconFrame.maxX + 6, y: y + (h - t.size.height) / 2, width: room, height: t.size.height)))
                chips.append((chip, iconFrame))
                y += h
                spoken.append(["Attachment", file.name, file.note].filter { !$0.isEmpty }.joined(separator: ", "))
            }
        }

        // The link to the place.
        var linkFrame: CGRect?
        var linkTitle = ""
        if let link = a.link {
            y += 10
            linkTitle = Self.linkTitle(link)
            let (l, _) = PromptLayout.clamped(PromptLayout.text(linkTitle, PromptFonts.font(.subheadline, category, weight: .medium), ChatPalette.tintText),
                                              width: innerW, maxLines: 1)
            let frame = CGRect(x: x, y: y, width: l.size.width, height: l.size.height)
            texts.append(PromptPlacedText(text: l, frame: frame))
            linkFrame = frame.insetBy(dx: -8, dy: -max(0, (44 - frame.height) / 2))
            y = frame.maxY
        }

        // The question.
        y += 14
        let questionFont = PromptFonts.font(.body, category, weight: .semibold)
        let qText = TextKitLayout(PromptLayout.text(a.question, questionFont, ChatPalette.label), width: innerW)
        texts.append(PromptPlacedText(text: qText, frame: CGRect(x: x, y: y, width: innerW, height: qText.size.height)))
        y += qText.size.height
        spoken.append(a.question)

        var placed: [(Int, CGRect)] = []
        let font = PromptFonts.button(category)
        var stacked = false
        var otherFrame: CGRect?
        var block: ReplyBlock?
        if let answer = card.answer {
            // Expanded answered ask: status + full sent reply.
            let status = AskCards.status(a, answer)
            let statusFont = PromptFonts.font(.footnote, category, weight: .semibold, cap: 24)
            let m = ceil(min(24, max(15, statusFont.pointSize * 1.15)))
            let lineH = ceil(statusFont.lineHeight), first = max(lineH, m)
            y += 10
            let (st, _) = PromptLayout.clamped(PromptLayout.text(status, statusFont, ChatPalette.label2), width: innerW - m - 6, maxLines: 1)
            texts.append(PromptPlacedText(text: st, frame: CGRect(x: x + m + 6, y: y + (first - lineH) / 2, width: innerW - m - 6, height: st.size.height)))
            symbols.append(PromptSymbol(frame: CGRect(x: x, y: y + (first - m) / 2, width: m, height: m), name: "checkmark.circle.fill", style: .success))
            y += max(first, st.size.height + (first - lineH) / 2)
            spoken.append(status)
            if case .sent(_, _, let reply) = answer, !reply.isEmpty {
                y += 6
                let w = innerW - m - 6
                let r = TextKitLayout(PromptLayout.text(reply, body, ChatPalette.label2), width: w)
                texts.append(PromptPlacedText(text: r, frame: CGRect(x: x + m + 6, y: y, width: w, height: r.size.height)))
                y += r.size.height
                spoken.append(reply)
            }
        } else {
            // A button per choice, side by side in equal widths; stacked full width (the bot's pick on top) at the
            // largest text sizes or when a title doesn't fit.
            let n = a.choices.count
            let h = max(44, ceil(font.lineHeight) + 16)
            let each = (innerW - CGFloat(max(0, n - 1)) * 8) / CGFloat(max(1, n))
            let needed = a.choices.map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) + 32 }
            stacked = category.isAccessibilityCategory || needed.contains { $0 > each }
            y += 12
            for i in 0..<n {
                if stacked {
                    placed.append((i, CGRect(x: x, y: y, width: innerW, height: h)))
                    y += h + (i < n - 1 ? 8 : 0)
                } else {
                    placed.append((i, CGRect(x: x + CGFloat(i) * (each + 8), y: y, width: each, height: h)))
                }
            }
            if !stacked { y += h }
            spoken.append("Choices: " + a.choices.joined(separator: ", "))
            if let picked = card.picked, a.choices.indices.contains(picked) { spoken.append("Picked: " + a.choices[picked]) }
            if let reply = card.reply, let to = a.replyTo {
                block = replyBlock(card, reply: reply, to: to, x: x, y: &y, innerW: innerW, category: category, texts: &texts, spoken: &spoken)
            }
            // "Something else…": quiet, centred, a full-height target.
            y += 6
            let o = TextKitLayout(PromptLayout.text(otherTitle, small, ChatPalette.label2), width: nil)
            let oFrame = CGRect(x: x + (innerW - o.size.width) / 2, y: y, width: o.size.width, height: o.size.height)
            texts.append(PromptPlacedText(text: o, frame: oFrame))
            otherFrame = CGRect(x: x, y: oFrame.midY - 22, width: innerW, height: 44)
            y = oFrame.maxY
        }
        // What happens next, while it waits.
        if card.answer == nil, !a.then.isEmpty {
            y += 10
            let t = TextKitLayout(PromptLayout.text(a.then, small, ChatPalette.label2), width: innerW)
            texts.append(PromptPlacedText(text: t, frame: CGRect(x: x, y: y, width: innerW, height: t.size.height)))
            y += t.size.height
            spoken.append(a.then)
        }

        let cardFrame = CGRect(x: side, y: top, width: cardW, height: ceil(y + padV - top))
        let accessibility = spoken.joined(separator: ". ")
        var geometry = AskCardGeometry(buttons: placed, titles: a.choices, font: font, stacked: stacked, other: otherFrame, link: linkFrame,
                                       linkTitle: linkTitle, quote: quote, chips: chips, disabled: card.answering || card.editingReply)
        geometry.picked = card.picked
        if card.answer != nil {
            geometry.toggleFrame = CGRect(x: side, y: top, width: cardW, height: headerBandH)
            geometry.toggleLabel = accessibility
            geometry.toggleExpanded = true
        }
        if let block {
            geometry.paper = block.paper
            geometry.replyButtons = block.buttons
            geometry.replyStacked = block.stacked
            geometry.showAll = block.showAll
            geometry.showAllTitle = block.showAllTitle
            geometry.bodyBar = block.bodyBar
            geometry.bodyBarTint = true
            geometry.footerDivider = block.footerDivider
        }
        var layout = PromptRowLayout(cardFrame: cardFrame, texts: texts, approval: nil, symbols: symbols, rules: [],
                                     accessibility: accessibility)
        layout.ask = geometry
        return RowLayout(height: ceil(cardFrame.maxY + 6), content: .prompt(layout))
    }

    /// [calm-chat] Compact two-line receipt for an answered ask card; tapping expands to full context & reply.
    private static func makeReceipt(_ card: AskCardRow, answer: AskCards.Answer, gap: CGFloat, width: CGFloat,
                                    category: UIContentSizeCategory) -> RowLayout {
        let a = card.ask
        let cardW = PromptLayout.cardWidth(for: width), innerW = cardW - 2 * padH
        let padV: CGFloat = 11
        let top = max(0, gap) + 4, x = side + padH
        let status = AskCards.status(a, answer)
        let headFont = PromptFonts.font(.subheadline, category, weight: .semibold, cap: 24)
        let bodyFont = PromptFonts.font(.subheadline, category)
        let mark = ceil(min(24, max(17, headFont.pointSize * 1.15)))
        let chevW = ceil(min(18, max(12, headFont.pointSize * 0.8)))

        let titleX = x + mark + 8
        let titleW = max(60, innerW - mark - 8 - chevW - 8)
        let (headText, _) = PromptLayout.clamped(PromptLayout.text(status, headFont, ChatPalette.label), width: titleW,
                                                 maxLines: category.isAccessibilityCategory ? 2 : 1)
        let headY = top + padV
        let firstH = max(mark, headText.size.height)
        let checkSymbol = PromptSymbol(frame: CGRect(x: x, y: headY + ((firstH - mark) / 2).rounded(), width: mark, height: mark),
                                       name: "checkmark.circle.fill", style: .success)
        let chevSymbol = PromptSymbol(frame: CGRect(x: x + innerW - chevW, y: headY + ((firstH - chevW) / 2).rounded(), width: chevW, height: chevW),
                                      name: "chevron.down", style: .blank)
        var texts = [PromptPlacedText(text: headText, frame: CGRect(x: titleX, y: headY + ((firstH - headText.size.height) / 2).rounded(),
                                                                    width: headText.size.width, height: headText.size.height))]
        var y = headY + firstH + 6
        let previewW = max(60, innerW - mark - 8)
        let stemX = x + ((mark - 2) / 2).rounded()

        var spoken = [source(a, category: category).1, a.question]
        let previewText: String
        let previewLines: Int
        if case .sent(_, _, let reply) = answer, !reply.isEmpty {
            previewText = reply
            previewLines = min(2, PromptRows.askSentLines)
            spoken.append(reply)
        } else {
            let tail = a.app.isEmpty ? "" : " · \(a.app)"
            previewText = a.question + tail
            previewLines = 1
        }
        spoken.append(status)

        let (preview, _) = PromptLayout.clamped(PromptLayout.text(previewText, bodyFont, ChatPalette.label2), width: previewW, maxLines: previewLines)
        texts.append(PromptPlacedText(text: preview, frame: CGRect(x: titleX, y: y, width: previewW, height: preview.size.height)))
        let bodyBar = CGRect(x: stemX, y: y + 1, width: 2, height: max(12, preview.size.height - 2))
        y += preview.size.height

        let cardFrame = CGRect(x: side, y: top, width: cardW, height: ceil(y + padV - top))
        let accessibility = spoken.joined(separator: ". ")
        var geometry = AskCardGeometry(buttons: [], titles: a.choices, font: PromptFonts.button(category), stacked: false,
                                       other: nil, link: nil, linkTitle: "", quote: nil, chips: [], disabled: false)
        geometry.bodyBar = bodyBar
        geometry.bodyBarTint = false
        geometry.toggleFrame = cardFrame
        geometry.toggleLabel = accessibility
        geometry.toggleExpanded = false
        var layout = PromptRowLayout(cardFrame: cardFrame, texts: texts, approval: nil, symbols: [checkSymbol, chevSymbol],
                                     rules: [], accessibility: accessibility)
        layout.ask = geometry
        return RowLayout(height: ceil(cardFrame.maxY + 4), content: .prompt(layout))
    }

    /// [calm-chat] Quiet one-line disclosure for an unanswered ask card left behind by later conversation;
    /// tapping opens a read-only drawer below it with zero live primary buttons.
    private static func makeFolded(_ card: AskCardRow, gap: CGFloat, width: CGFloat, category: UIContentSizeCategory) -> RowLayout {
        let a = card.ask
        let cardW = PromptLayout.cardWidth(for: width)
        let font = PromptFonts.font(.footnote, category, cap: 22)
        let strongFont = PromptFonts.font(.footnote, category, weight: .semibold, cap: 22)
        let iconSide = ceil(min(22, max(15, font.pointSize * 1.1)))
        let chevW = ceil(min(18, max(11, font.pointSize * 0.85)))
        let rowH = max(32, ceil(font.lineHeight) + 10)
        let top = max(0, gap)

        let flatQ = a.question.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        let label = NSMutableAttributedString(attributedString: PromptLayout.text(flatQ, strongFont, ChatPalette.label2))
        label.append(PromptLayout.text(" · Unanswered", font, ChatPalette.label2))

        let textX = side + iconSide + 7
        let maxTextW = max(60, cardW - iconSide - 7 - 6 - chevW)
        let (lineLayout, _) = PromptLayout.clamped(label, width: maxTextW, maxLines: 1)
        let lineY = top + ((rowH - lineLayout.size.height) / 2).rounded()
        let textFrame = CGRect(x: textX, y: lineY, width: lineLayout.size.width, height: lineLayout.size.height)
        let leadSymbol = PromptSymbol(frame: CGRect(x: side, y: top + ((rowH - iconSide) / 2).rounded(), width: iconSide, height: iconSide),
                                      name: AskCards.quietGlyph(a), style: .quiet)
        let chevSymbol = PromptSymbol(frame: CGRect(x: textFrame.maxX + 6, y: top + ((rowH - chevW) / 2).rounded(), width: chevW, height: chevW),
                                      name: card.expanded ? "chevron.up" : "chevron.down", style: .blank)
        let rowWidth = min(cardW, chevSymbol.frame.maxX - side)
        let tapH = max(44, rowH)
        let toggleFrame = CGRect(x: side - 6, y: top + (rowH - tapH) / 2, width: rowWidth + 12, height: tapH)
        let pillH = min(rowH, ceil(max(font.lineHeight, iconSide)) + 8)
        let backingFrame = CGRect(x: side - 8, y: top + ((rowH - pillH) / 2).rounded(), width: rowWidth + 16, height: pillH)
        let accessibility = [source(a, category: category).1, a.question, "Unanswered"].filter { !$0.isEmpty }.joined(separator: ". ")

        guard card.expanded else {
            var geometry = AskCardGeometry(buttons: [], titles: a.choices, font: PromptFonts.button(category), stacked: false,
                                           other: nil, link: nil, linkTitle: "", quote: nil, chips: [], disabled: false)
            geometry.toggleFrame = toggleFrame
            geometry.toggleLabel = accessibility
            geometry.toggleExpanded = false
            geometry.backingFrame = backingFrame
            var layout = PromptRowLayout(cardFrame: nil, texts: [PromptPlacedText(text: lineLayout, frame: textFrame)],
                                         approval: nil, symbols: [leadSymbol, chevSymbol], rules: [], accessibility: accessibility)
            layout.ask = geometry
            return RowLayout(height: ceil(top + rowH + 2), content: .prompt(layout))
        }

        // Expanded read-only drawer below the disclosure line.
        let innerW = cardW - 2 * padH
        let cardTop = top + rowH + 4
        let x = side + padH
        var y = cardTop + padV
        var texts = [PromptPlacedText(text: lineLayout, frame: textFrame)]
        let (srcText, _) = source(a, category: category)
        let (srcLayout, _) = PromptLayout.clamped(srcText, width: innerW, maxLines: 2)
        texts.append(PromptPlacedText(text: srcLayout, frame: CGRect(x: x, y: y, width: innerW, height: srcLayout.size.height)))
        y += srcLayout.size.height + 8

        var quote: CGRect?
        if !a.quote.isEmpty {
            let inset: CGFloat = 12
            let (q, _) = PromptLayout.clamped(PromptLayout.text("“\(a.quote)”", PromptFonts.font(.subheadline, category), ChatPalette.label2),
                                              width: innerW - inset, maxLines: quoteLines)
            texts.append(PromptPlacedText(text: q, frame: CGRect(x: x + inset, y: y, width: innerW - inset, height: q.size.height)))
            quote = CGRect(x: x, y: y, width: 2.5, height: q.size.height)
            y += q.size.height + 8
        }
        var linkFrame: CGRect?
        var linkTitle = ""
        if let link = a.link {
            linkTitle = Self.linkTitle(link)
            let (l, _) = PromptLayout.clamped(PromptLayout.text(linkTitle, PromptFonts.font(.subheadline, category, weight: .medium), ChatPalette.tintText),
                                              width: innerW, maxLines: 1)
            let frame = CGRect(x: x, y: y, width: l.size.width, height: l.size.height)
            texts.append(PromptPlacedText(text: l, frame: frame))
            linkFrame = frame.insetBy(dx: -8, dy: -max(0, (44 - frame.height) / 2))
            y = frame.maxY + 8
        }
        let qText = TextKitLayout(PromptLayout.text(a.question, PromptFonts.font(.subheadline, category, weight: .semibold), ChatPalette.label2), width: innerW)
        texts.append(PromptPlacedText(text: qText, frame: CGRect(x: x, y: y, width: innerW, height: qText.size.height)))
        y += qText.size.height
        let cardFrame = CGRect(x: side, y: cardTop, width: cardW, height: ceil(y + padV - cardTop))

        var geometry = AskCardGeometry(buttons: [], titles: a.choices, font: PromptFonts.button(category), stacked: false,
                                       other: nil, link: linkFrame, linkTitle: linkTitle, quote: quote, chips: [], disabled: false)
        geometry.toggleFrame = toggleFrame
        geometry.toggleLabel = accessibility
        geometry.toggleExpanded = true
        geometry.backingFrame = backingFrame
        var layout = PromptRowLayout(cardFrame: cardFrame, texts: texts, approval: nil, symbols: [leadSymbol, chevSymbol],
                                     rules: [], accessibility: accessibility)
        layout.ask = geometry
        return RowLayout(height: ceil(cardFrame.maxY + 4), content: .prompt(layout))
    }

    /// [asks v2] What the reply block placed: its body region, accent bar, divider, Send and Edit, Show All.
    struct ReplyBlock {
        var paper: CGRect
        var bodyBar: CGRect
        var footerDivider: CGRect
        var buttons: [(DraftButton, CGRect)]
        var stacked: Bool
        var showAll: CGRect?
        var showAllTitle: String
    }

    /// [asks v2] A picked choice's ready reply, under the buttons: "Reply to Dana Reyes · Slack" (· Edited), the words
    /// beside a clean tint left accent bar (clamped until Show All), subtle divider, then Edit and Send trailing.
    static func replyBlock(_ card: AskCardRow, reply: String, to: AskCards.ReplyTo, x: CGFloat, y: inout CGFloat, innerW: CGFloat,
                           category: UIContentSizeCategory, texts: inout [PromptPlacedText], spoken: inout [String]) -> ReplyBlock {
        y += 14
        let headFont = PromptFonts.font(.footnote, category, weight: .semibold, cap: 24)
        let heading = AskCards.replyHeading(to) + (card.edited ? " · Edited" : "")
        let (h, _) = PromptLayout.clamped(PromptLayout.text(heading, headFont, ChatPalette.label2), width: innerW, maxLines: 2)
        texts.append(PromptPlacedText(text: h, frame: CGRect(x: x, y: y, width: innerW, height: h.size.height)))
        y += h.size.height + 8
        let inset: CGFloat = 12
        let paperTop = y
        let wx = x + inset, wordsW = max(60, innerW - inset)
        let (words, cut) = PromptLayout.clamped(PromptLayout.text(reply, PromptFonts.font(.body, category), ChatPalette.label), width: wordsW,
                                                maxLines: card.expanded ? 0 : PromptRows.askReplyLines)
        texts.append(PromptPlacedText(text: words, frame: CGRect(x: wx, y: y, width: wordsW, height: words.size.height)))
        let bodyBar = CGRect(x: x + 2, y: y + 2, width: 2.5, height: max(14, words.size.height - 4))
        y += words.size.height
        spoken.append(AskCards.replySpoken(to, reply) + (card.edited ? " (edited)" : ""))
        var showAll: CGRect?
        let showAllTitle = card.expanded ? "Show Less" : "Show All"
        if cut || card.expanded && PromptLayout.lineCount(words) > PromptRows.askReplyLines {
            let more = TextKitLayout(PromptLayout.text(showAllTitle, PromptFonts.font(.footnote, category), ChatPalette.tintText), width: nil)
            let frame = CGRect(x: wx, y: y + 6, width: more.size.width, height: more.size.height)
            texts.append(PromptPlacedText(text: more, frame: frame))
            showAll = frame.insetBy(dx: -8, dy: -(44 - frame.height) / 2)
            y = frame.maxY
        }
        let paper = CGRect(x: x, y: paperTop, width: innerW, height: max(1, y - paperTop))
        y += 12
        let footerDivider = CGRect(x: x, y: y, width: innerW, height: 0)
        y += 10
        // Edit and Send.
        let font = PromptFonts.button(category)
        let order: [DraftButton] = [.edit, .send]
        let bh = max(44, ceil(font.lineHeight) + 16)
        let widths = order.map { ceil((PromptLayout.draftButtonTitle($0) as NSString).size(withAttributes: [.font: font]).width) + 32 }
        let stacked = category.isAccessibilityCategory || widths.reduce(0, +) + 8 > innerW
        var placed: [(DraftButton, CGRect)] = []
        if stacked {
            for b in order.reversed() {
                placed.append((b, CGRect(x: x, y: y, width: innerW, height: bh)))
                y += bh + 8
            }
            y -= 8
        } else {
            var right = x + innerW
            for (b, w) in zip(order, widths).reversed() {
                right -= w
                placed.append((b, CGRect(x: right, y: y, width: w, height: bh)))
                right -= 8
            }
            y += bh
        }
        return ReplyBlock(paper: paper, bodyBar: bodyBar, footerDivider: footerDivider, buttons: placed, stacked: stacked,
                          showAll: showAll, showAllTitle: showAllTitle)
    }
}

// MARK: - View

/// The ask card's own drawing over the row (the cell places it over the whole row; touches elsewhere pass through):
/// the choices' buttons, "Something else…", the link, the bar beside the quote and the chips' outlines.
final class AskCardView: UIView {
    var onChoice: ((Int) -> Void)?
    var onOther: (() -> Void)?
    var onLink: (() -> Void)?
    /// [asks v2] The ready reply's Send / Edit, and its Show All.
    var onReply: ((DraftButton) -> Void)?
    var onShowAll: (() -> Void)?
    /// [calm-chat] Tap on a folded/answered ask receipt to expand or collapse.
    var onToggle: (() -> Void)?
    private var buttons: [UIButton] = []
    private var replyButtons: [DraftButton: UIButton] = [:]
    private let showAll = UIControl()
    private let other = UIControl()
    private let link = UIControl()
    private let toggle = UIControl()
    private let bar = UIView()
    private let replyBar = UIView()
    private let replyDivider = UIView()
    private var replyBarTint = false
    private var chipViews: [(UIView, UIImageView)] = []
    /// VoiceOver's order after the card itself: the link, the buttons (the bot's pick first), Something else.
    private(set) var ordered: [UIView] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        bar.isUserInteractionEnabled = false
        bar.layer.cornerRadius = 1.5
        addSubview(bar)
        replyBar.isUserInteractionEnabled = false
        replyBar.isHidden = true
        replyBar.layer.cornerRadius = 1.25
        addSubview(replyBar)
        replyDivider.isUserInteractionEnabled = false
        replyDivider.isHidden = true
        addSubview(replyDivider)
        toggle.isHidden = true
        toggle.isAccessibilityElement = true
        toggle.accessibilityTraits = .button
        toggle.accessibilityIdentifier = "ask.toggle"
        toggle.addAction(UIAction { [weak self] _ in self?.onToggle?() }, for: .touchUpInside)
        addSubview(toggle)
        PointerEffects.surface(toggle)
        for (control, id, label) in [(other, "ask.other", AskCardLayout.otherTitle), (link, "ask.link", ""), (showAll, "ask.showAll", "Show All")] {
            control.isAccessibilityElement = true
            control.accessibilityTraits = .button
            control.accessibilityIdentifier = id
            control.accessibilityLabel = label
            addSubview(control)
        }
        other.addAction(UIAction { [weak self] _ in self?.onOther?() }, for: .touchUpInside)
        link.addAction(UIAction { [weak self] _ in self?.onLink?() }, for: .touchUpInside)
        showAll.addAction(UIAction { [weak self] _ in self?.onShowAll?() }, for: .touchUpInside)
        link.accessibilityTraits = .link
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (view: AskCardView, _) in view.recolor() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    func configure(_ g: AskCardGeometry, cardFrame: CGRect? = nil) {
        bar.isHidden = g.quote == nil
        bar.frame = g.quote ?? .zero
        replyBar.isHidden = g.bodyBar == nil
        replyBar.frame = g.bodyBar ?? .zero
        replyBarTint = g.bodyBarTint
        replyDivider.isHidden = g.footerDivider == nil
        if let div = g.footerDivider {
            let hair = HQShape.pixel(traitCollection.displayScale)
            replyDivider.frame = CGRect(x: div.minX, y: div.minY, width: div.width, height: hair)
        }
        while chipViews.count < g.chips.count {
            let chip = UIView()
            chip.isUserInteractionEnabled = false
            chip.layer.cornerCurve = .continuous
            let icon = UIImageView(image: UIImage(systemName: "doc"))
            icon.contentMode = .scaleAspectFit
            icon.isUserInteractionEnabled = false
            insertSubview(chip, at: 0)
            addSubview(icon)
            chipViews.append((chip, icon))
        }
        for (i, (chip, icon)) in chipViews.enumerated() {
            let shown = i < g.chips.count
            chip.isHidden = !shown
            icon.isHidden = !shown
            guard shown else { continue }
            chip.frame = g.chips[i].chip
            chip.layer.cornerRadius = chip.frame.height / 2
            icon.frame = g.chips[i].icon
            icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: icon.frame.height * 0.85, weight: .regular)
        }
        while buttons.count < g.buttons.count { buttons.append(make(buttons.count)) }
        ordered = []
        if let tf = g.toggleFrame {
            toggle.isHidden = false
            toggle.frame = tf
            toggle.accessibilityLabel = g.toggleLabel
            toggle.accessibilityValue = g.toggleExpanded ? "Expanded" : "Collapsed"
            if let cardFrame, !g.toggleExpanded {
                PointerEffects.fit(toggle, card: cardFrame, radius: ChatMetrics.insetCardRadius)
            } else {
                toggle.layer.cornerRadius = 8
                PointerEffects.outlineDidLayout(toggle)
            }
            ordered.append(toggle)
        } else {
            toggle.isHidden = true
        }
        if let frame = g.link {
            link.isHidden = false
            link.frame = frame
            link.accessibilityLabel = g.linkTitle.replacingOccurrences(of: " ↗", with: "")
            ordered.append(link)
        } else {
            link.isHidden = true
        }
        for (i, button) in buttons.enumerated() {
            guard let placed = g.buttons.first(where: { $0.0 == i }), g.titles.indices.contains(i) else { button.isHidden = true; continue }
            button.isHidden = false
            button.frame = placed.1
            // [asks v2] A picked choice stays filled and the others go outline; until then the bot's pick is filled.
            let style: ChoiceStyle = g.picked.map { $0 == i ? .filled : .outline } ?? (i == 0 ? .filled : .quiet)
            button.configuration = config(style, title: g.titles[i], font: g.font)
            button.accessibilityTraits = g.picked == i ? [.button, .selected] : .button
            button.isEnabled = !g.disabled
            ordered.append(button)
        }
        // [asks v2] The ready reply's Show All, then Send and Edit (Send first when stacked; Edit, Send in a row).
        showAll.isHidden = g.showAll == nil
        showAll.frame = g.showAll ?? .zero
        showAll.accessibilityLabel = g.showAllTitle
        if g.showAll != nil { ordered.append(showAll) }
        var shown = Set<DraftButton>()
        for (kind, frame) in g.replyButtons {
            let button = replyButtons[kind] ?? makeReply(kind)
            button.isHidden = false
            button.frame = frame
            button.configuration = config(kind == .send ? .filled : .quiet, title: PromptLayout.draftButtonTitle(kind), font: g.font)
            button.isEnabled = !g.disabled
            shown.insert(kind)
            ordered.append(button)
        }
        for (kind, button) in replyButtons where !shown.contains(kind) { button.isHidden = true }
        other.isHidden = g.other == nil
        other.frame = g.other ?? .zero
        other.isEnabled = !g.disabled
        if g.other != nil { ordered.append(other) }
        recolor()
    }

    private func recolor() {
        bar.backgroundColor = ChatPalette.tint.withAlphaComponent(0.55)
        replyBar.backgroundColor = replyBarTint ? ChatPalette.tint.withAlphaComponent(0.55) : ChatPalette.separator
        replyDivider.backgroundColor = ChatPalette.separator.withAlphaComponent(0.55)
        let edge = ChatPalette.separator.resolvedColor(with: traitCollection)
        for (chip, icon) in chipViews {
            chip.layer.borderColor = edge.cgColor
            chip.layer.borderWidth = 1
            icon.tintColor = ChatPalette.label2
        }
    }

    private func make(_ index: Int) -> UIButton {
        let button = UIButton(type: .system)
        button.accessibilityIdentifier = "ask.choice.\(index + 1)"
        button.addAction(UIAction { [weak self] _ in self?.onChoice?(index) }, for: .primaryActionTriggered)
        addSubview(button)
        #if targetEnvironment(macCatalyst)
        PointerEffects.button(button)
        #endif
        return button
    }

    private func makeReply(_ kind: DraftButton) -> UIButton {
        let button = UIButton(type: .system)
        button.accessibilityIdentifier = "ask.reply.\(kind)"
        button.addAction(UIAction { [weak self] _ in self?.onReply?(kind) }, for: .primaryActionTriggered)
        addSubview(button)
        #if targetEnvironment(macCatalyst)
        PointerEffects.button(button)
        #endif
        replyButtons[kind] = button
        return button
    }

    enum ChoiceStyle { case filled, quiet, outline }

    /// Filled in the tint (the bot's pick, a picked choice, Send), on the quiet fill (the others, Edit: a draft card's
    /// Send and Edit), or an outline (the choices you didn't pick).
    private func config(_ style: ChoiceStyle, title: String, font: UIFont) -> UIButton.Configuration {
        var c: UIButton.Configuration = .filled()
        switch style {
        case .filled:
            c.baseBackgroundColor = ChatPalette.tint
            c.baseForegroundColor = ChatPalette.onTint
        case .quiet:
            c.baseBackgroundColor = ChatPalette.fill2
            c.baseForegroundColor = ChatPalette.label
        case .outline:
            c.baseBackgroundColor = .clear
            c.baseForegroundColor = ChatPalette.label
            c.background.strokeColor = ChatPalette.separator
            c.background.strokeWidth = 1
        }
        c.cornerStyle = .capsule
        c.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14)
        c.title = title
        c.titleLineBreakMode = .byTruncatingTail
        c.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in var a = a; a.font = font; return a }
        return c
    }
}
