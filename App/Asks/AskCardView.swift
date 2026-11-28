import UIKit

// [asks] Concept 1 — Elevated Decision Card:
// Bare asks (no external app/sender/link) omit header chrome completely and lead with the 17 pt semibold question,
// followed directly by the `then` safety promise (iOS Alert order), a hairline, full-width wrapping action rows
// (no hollow radio circles, no trailing chevrons), an optional WCAG-checked `Recommended` pill + rationale, and
// a left-aligned "Something else…" row with a quiet trailing pencil.
// Rich external asks add a Grok-style header with a real brand icon tile (`AppBrandTileView`) and trailing `↗` link,
// a muted 2 pt quote bar (clamped at 4 lines with independent "More" toggle), and borderless `fill4` attachment chips.
// v2 ready replies expand inline as an accordion directly underneath the picked choice row.

// MARK: - Layout

nonisolated struct AskCardGeometry: @unchecked Sendable {
    struct ChoiceRow: Sendable {
        var index: Int
        var frame: CGRect
        var title: String
        var isPicked: Bool
        var isRecommended: Bool
        var hasReply: Bool
        var why: String
        /// Layout-drawn `Recommended` badge pill frame in row coordinates (nil when not recommended).
        var tagFrame: CGRect?
        /// Trailing checkmark frame when picked in v2.
        var checkFrame: CGRect?
        /// Bottom corners rounded if this row is somehow last in the card.
        var roundBottom: Bool
    }

    struct Divider: Sendable {
        var frame: CGRect
        var fullWidth: Bool
    }

    /// Each choice's interactive row (0-based index) in row coordinates; empty once answered or collapsed.
    var buttons: [(Int, CGRect)]
    var choiceRows: [ChoiceRow] = []
    var titles: [String]
    var font: UIFont
    var stacked: Bool
    /// "Something else…" full-width row (and trailing pencil frame) in row coordinates.
    var other: CGRect?
    var otherVisual: CGRect? = nil
    var otherPencilFrame: CGRect? = nil
    /// Trailing `↗` link touch target & glyph frame in header (or body link on expanded receipts).
    var link: CGRect?
    var linkGlyphFrame: CGRect? = nil
    var linkTitle: String
    /// Brand icon tile frame and spec (header on waiting/expanded cards, leading mark on receipts & stale disclosures).
    var brandFrame: CGRect? = nil
    var brandSpec: AppBrandResolver.Spec? = nil
    /// The muted vertical bar beside their quoted words, plus optional "More" / "Show less" hit target.
    var quote: CGRect?
    var quoteToggle: CGRect? = nil
    var quoteToggleTitle: String = ""
    /// Each attachment's borderless `fill4` chip and document/paperclip icon frame.
    var chips: [(chip: CGRect, icon: CGRect)]
    /// Hairline dividers drawn inside the card (header separator, choice list top rule, inset row rules).
    var dividers: [Divider] = []
    /// The choices wait while "Something else…" or "Editing Reply" composer strip is open.
    var disabled: Bool
    /// [asks v2] The choice picked (0-based) whose ready reply expands inline underneath it.
    var picked: Int? = nil
    /// [asks v2] Background band behind the picked row + inline accordion drawer.
    var pickedBand: CGRect? = nil
    /// [asks v2] The inset `fill4` paper panel holding the ready reply, its Edit/Send buttons, and Show All target.
    var paper: CGRect? = nil
    var replyButtons: [(DraftButton, CGRect)] = []
    var replyStacked = false
    var showAll: CGRect? = nil
    var showAllTitle = ""
    /// Receipt/folded disclosure tap target and frosted backing pill over chat wallpapers.
    var bodyBar: CGRect? = nil
    var bodyBarTint = false
    var footerDivider: CGRect? = nil
    var toggleFrame: CGRect? = nil
    var toggleLabel = ""
    var toggleExpanded = false
    var backingFrame: CGRect? = nil
}

nonisolated enum AskCardLayout {
    static let side: CGFloat = 16, padH: CGFloat = 16, padV: CGFloat = 14
    static let otherTitle = "Something else…"
    static let quoteLines = 4

    static func linkTitle(_ link: AskCards.Link) -> String { link.title + " ↗" }

    /// Bold-Text-aware font helper (steps drawn weights only when UIKit has not already bolded them).
    private static func font(_ style: UIFont.TextStyle, _ category: UIContentSizeCategory,
                             weight: UIFont.Weight = .regular, cap: CGFloat? = nil) -> UIFont {
        let stepped = HQFont.drawn(weight, bold: HQAccessibility.stepsDrawnWeights)
        return PromptFonts.font(style, category, weight: stepped, cap: cap)
    }

    private static func linkText(_ string: String, _ font: UIFont, _ color: UIColor) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byWordWrapping
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: p]
        if HQAccessibility.buttonShapes { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        return NSAttributedString(string: string, attributes: attrs)
    }

    /// Source line for rich external asks: App (semibold) · Sender · Place · When (quiet).
    static func source(_ ask: AskCards.Ask, category: UIContentSizeCategory) -> (NSAttributedString, String) {
        let strong = font(.footnote, category, weight: .semibold, cap: 22)
        let quiet = font(.footnote, category, weight: .regular, cap: 22)
        var lead = ask.app
        var rest = [ask.from, ask.place, ask.when].filter { !$0.isEmpty }
        if lead.isEmpty, !rest.isEmpty { lead = rest.removeFirst() }
        if lead.isEmpty { lead = ask.link?.title ?? "" }
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
        return makeCard(card, top: max(0, gap) + 8, width: width, category: category,
                        leadingTexts: [], leadingSymbols: [], toggleOverride: nil, backingFrame: nil)
    }

    /// Shared elevated Concept 1 decision card builder used for live waiting asks, expanded receipts, and expanded
    /// (still-answerable) stale folds.
    private static func makeCard(
        _ card: AskCardRow,
        top: CGFloat,
        width: CGFloat,
        category: UIContentSizeCategory,
        leadingTexts: [PromptPlacedText],
        leadingSymbols: [PromptSymbol],
        toggleOverride: (frame: CGRect, label: String, expanded: Bool)?,
        backingFrame: CGRect?
    ) -> RowLayout {
        let a = card.ask
        let cardW = PromptLayout.cardWidth(for: width)
        let innerW = cardW - 2 * padH
        let x = side + padH
        var texts = leadingTexts
        var symbols = leadingSymbols
        var dividers: [AskCardGeometry.Divider] = []
        var spoken: [String] = []

        let brandSpec = a.hasExternalSource ? AppBrandResolver.resolve(ask: a) : nil
        var brandFrame: CGRect? = nil
        var linkFrame: CGRect? = nil
        var linkGlyphFrame: CGRect? = nil
        var linkTitle = ""

        var y = top
        var headerBandH: CGFloat = 44

        // 1. Header bar — ONLY for rich external asks (bare asks lead directly with the question!).
        if a.hasExternalSource {
            let headPadV: CGFloat = 11
            let headFont = font(.footnote, category, weight: .semibold, cap: 22)
            let brandSide: CGFloat = brandSpec != nil ? ceil(min(28, max(22, headFont.pointSize * 1.65))) : 0
            let textX = brandSide > 0 ? x + brandSide + 9 : x
            let showChev = card.answer != nil
            let showHeaderLink = !showChev && a.link != nil
            let trailGlyphSide: CGFloat = showChev
                ? ceil(min(18, max(13, headFont.pointSize * 0.95)))
                : (showHeaderLink ? ceil(min(18, max(14, headFont.pointSize * 1.0))) : 0)
            let trailReserve: CGFloat = trailGlyphSide > 0 ? trailGlyphSide + 12 : 0
            let sourceMaxW = max(60, x + innerW - textX - trailReserve)
            let (sourceText, sourceSpoken) = source(a, category: category)
            let (s, _) = PromptLayout.clamped(sourceText, width: sourceMaxW, maxLines: 2)
            let headContentY = top + headPadV
            let firstH = max(brandSide, s.size.height)
            if brandSide > 0 {
                brandFrame = CGRect(x: x, y: headContentY + ((firstH - brandSide) / 2).rounded(),
                                    width: brandSide, height: brandSide)
            }
            texts.append(PromptPlacedText(
                text: s,
                frame: CGRect(x: textX, y: headContentY + ((firstH - s.size.height) / 2).rounded(),
                              width: s.size.width, height: s.size.height)
            ))
            if showChev {
                symbols.append(PromptSymbol(
                    frame: CGRect(x: x + innerW - trailGlyphSide,
                                  y: headContentY + ((firstH - trailGlyphSide) / 2).rounded(),
                                  width: trailGlyphSide, height: trailGlyphSide),
                    name: "chevron.up", style: .blank
                ))
            } else if showHeaderLink, let link = a.link {
                linkTitle = Self.linkTitle(link)
                let gx = x + innerW - trailGlyphSide
                let gy = headContentY + ((firstH - trailGlyphSide) / 2).rounded()
                linkGlyphFrame = CGRect(x: gx, y: gy, width: trailGlyphSide, height: trailGlyphSide)
                let midY = headContentY + firstH / 2
                linkFrame = CGRect(x: min(gx - 12, side + cardW - 48), y: midY - 22, width: 48, height: 44)
            }
            if !sourceSpoken.isEmpty { spoken.append(sourceSpoken) }
            y = headContentY + firstH + headPadV
            headerBandH = max(44, y - top)
            dividers.append(AskCardGeometry.Divider(frame: CGRect(x: side, y: y, width: cardW, height: 0), fullWidth: true))
        } else {
            // Bare expanded receipt still needs a quiet collapse chevron in the top-trailing corner.
            if card.answer != nil {
                let chevSide: CGFloat = 14
                symbols.append(PromptSymbol(
                    frame: CGRect(x: x + innerW - chevSide, y: top + 16, width: chevSide, height: chevSide),
                    name: "chevron.up", style: .blank
                ))
                headerBandH = 44
            }
            y = top + 16
        }

        let bodyFont = font(.subheadline, category)
        let smallFont = font(.footnote, category)
        var hasContentAboveQuestion = false

        // 2. Quoted external message (2 pt muted left bar, 4-line clamp + independent "More" toggle).
        var quoteRect: CGRect?
        var quoteToggleRect: CGRect?
        var quoteToggleTitle = ""
        if !a.quote.isEmpty {
            if a.hasExternalSource { y += 14 }
            let inset: CGFloat = 11
            let quoteW = max(60, innerW - inset)
            let (q, cut) = PromptLayout.clamped(
                PromptLayout.text("“\(a.quote)”", bodyFont, ChatPalette.label2),
                width: quoteW,
                maxLines: card.quoteExpanded ? 0 : quoteLines
            )
            texts.append(PromptPlacedText(text: q, frame: CGRect(x: x + inset, y: y, width: quoteW, height: q.size.height)))
            quoteRect = CGRect(x: x, y: y + 2, width: 2, height: max(12, q.size.height - 4))
            y += q.size.height
            spoken.append(a.quote)
            if cut || (card.quoteExpanded && PromptLayout.lineCount(q) > quoteLines) {
                quoteToggleTitle = card.quoteExpanded ? "Show less" : "More"
                let moreFont = font(.footnote, category, weight: .medium, cap: 22)
                let moreLayout = TextKitLayout(linkText(quoteToggleTitle, moreFont, ChatPalette.tintText), width: nil)
                let moreFrame = CGRect(x: x + inset, y: y + 4, width: moreLayout.size.width, height: moreLayout.size.height)
                texts.append(PromptPlacedText(text: moreLayout, frame: moreFrame))
                quoteToggleRect = moreFrame.insetBy(dx: -8, dy: -max(0, (44 - moreFrame.height) / 2))
                y = moreFrame.maxY
            }
            hasContentAboveQuestion = true
        }

        // 3. Borderless `fill4` attachment chips.
        var chips: [(CGRect, CGRect)] = []
        if !a.attachments.isEmpty {
            y += hasContentAboveQuestion ? 10 : (a.hasExternalSource ? 14 : 0)
            let chipFont = font(.footnote, category, cap: 22)
            let nameFont = font(.footnote, category, weight: .medium, cap: 22)
            let lineH = ceil(chipFont.lineHeight)
            let icon = ceil(chipFont.pointSize * 1.0)
            let padX: CGFloat = 10
            let h = lineH + 10
            for (i, file) in a.attachments.enumerated() {
                if i > 0 { y += 6 }
                let words = NSMutableAttributedString(attributedString: PromptLayout.text(file.name, nameFont, ChatPalette.label))
                if !file.note.isEmpty { words.append(PromptLayout.text(" · " + file.note, chipFont, ChatPalette.label2)) }
                let room = max(40, innerW - 2 * padX - icon - 6)
                let (t, _) = PromptLayout.clamped(words, width: room, maxLines: 1)
                let chipW = min(innerW, ceil(t.size.width) + 2 * padX + icon + 6)
                let chip = CGRect(x: x, y: y, width: chipW, height: h)
                let iconFrame = CGRect(x: x + padX, y: y + ((h - icon) / 2).rounded(), width: icon, height: icon)
                texts.append(PromptPlacedText(
                    text: t,
                    frame: CGRect(x: iconFrame.maxX + 6, y: y + ((h - t.size.height) / 2).rounded(),
                                  width: min(room, ceil(t.size.width)), height: t.size.height)
                ))
                chips.append((chip, iconFrame))
                y += h
                spoken.append(["Attachment", file.name, file.note].filter { !$0.isEmpty }.joined(separator: ", "))
            }
            hasContentAboveQuestion = true
        }

        // Expanded answered receipt with a link: show the link cleanly in the body so the header remains collapse-only.
        if card.answer != nil, let link = a.link {
            y += hasContentAboveQuestion ? 10 : (a.hasExternalSource ? 14 : 0)
            linkTitle = Self.linkTitle(link)
            let lf = font(.footnote, category, weight: .medium, cap: 22)
            let (l, _) = PromptLayout.clamped(linkText(linkTitle, lf, ChatPalette.tintText), width: innerW, maxLines: 1)
            let frame = CGRect(x: x, y: y, width: l.size.width, height: l.size.height)
            texts.append(PromptPlacedText(text: l, frame: frame))
            linkFrame = frame.insetBy(dx: -8, dy: -max(0, (44 - frame.height) / 2))
            y = frame.maxY
            hasContentAboveQuestion = true
        }

        // 4. Question (17 pt semibold — the ONLY bold focal text) + `then` safety promise right beneath (iOS Alert order).
        if hasContentAboveQuestion {
            y += 14
        } else if a.hasExternalSource {
            y += 14
        }
        let questionW = (!a.hasExternalSource && card.answer != nil) ? max(60, innerW - 24) : innerW
        let questionFont = font(.body, category, weight: .semibold)
        let qText = TextKitLayout(PromptLayout.text(a.question, questionFont, ChatPalette.label), width: questionW)
        texts.append(PromptPlacedText(text: qText, frame: CGRect(x: x, y: y, width: questionW, height: qText.size.height)))
        y += qText.size.height
        spoken.append(a.question)

        if card.answer == nil, !a.then.isEmpty {
            y += 5
            let thenLayout = TextKitLayout(PromptLayout.text(a.then, bodyFont, ChatPalette.label2), width: innerW)
            texts.append(PromptPlacedText(text: thenLayout, frame: CGRect(x: x, y: y, width: innerW, height: thenLayout.size.height)))
            y += thenLayout.size.height
            spoken.append(a.then)
        }

        // 5. Choices & inline v2 accordion drawer (when unanswered), OR answered status + full sent reply.
        var placed: [(Int, CGRect)] = []
        var choiceRows: [AskCardGeometry.ChoiceRow] = []
        let btnFont = PromptFonts.button(category)
        var otherFrame: CGRect?
        var otherVisual: CGRect?
        var otherPencilFrame: CGRect?
        var block: ReplyBlock?
        var pickedBand: CGRect?

        if let answer = card.answer {
            let status = AskCards.status(a, answer)
            let statusFont = font(.footnote, category, weight: .semibold, cap: 24)
            let m = ceil(min(22, max(15, statusFont.pointSize * 1.15)))
            let lineH = ceil(statusFont.lineHeight)
            let first = max(lineH, m)
            y += 14
            dividers.append(AskCardGeometry.Divider(frame: CGRect(x: side, y: y, width: cardW, height: 0), fullWidth: true))
            y += 12
            let statusIcon: (name: String, style: PromptSymbol.Style) = {
                switch card.delivery {
                case .sent: ("checkmark.circle.fill", .quiet)
                case .sending, .queued: ("clock", .quiet)
                case .failed: ("exclamationmark.circle", .dim)
                }
            }()
            let (st, _) = PromptLayout.clamped(PromptLayout.text(status, statusFont, ChatPalette.label2), width: innerW - m - 6, maxLines: 2)
            texts.append(PromptPlacedText(text: st, frame: CGRect(x: x + m + 6, y: y + (first - lineH) / 2, width: innerW - m - 6, height: st.size.height)))
            symbols.append(PromptSymbol(frame: CGRect(x: x, y: y + (first - m) / 2, width: m, height: m), name: statusIcon.name, style: statusIcon.style))
            y += max(first, st.size.height + (first - lineH) / 2)
            spoken.append(status)
            if case .sent(_, _, let reply) = answer, !reply.isEmpty {
                y += 8
                let w = innerW - m - 6
                let r = TextKitLayout(PromptLayout.text(reply, bodyFont, ChatPalette.label2), width: w)
                texts.append(PromptPlacedText(text: r, frame: CGRect(x: x + m + 6, y: y, width: w, height: r.size.height)))
                y += r.size.height
                spoken.append(reply)
            }
            y += padV
        } else {
            // Hairline-divided full-width action list.
            y += 14
            dividers.append(AskCardGeometry.Divider(frame: CGRect(x: side, y: y, width: cardW, height: 0), fullWidth: true))

            let hasAnyReply = a.replyTo != nil && a.replies.contains { !$0.isEmpty }
            let rowFont = font(.body, category, weight: .regular)
            let pickedFont = font(.body, category, weight: .semibold)
            let tagFont = font(.caption1, category, weight: .semibold, cap: 18)
            let cueFont = font(.caption1, category, weight: .regular, cap: 18)
            let whyFont = font(.footnote, category, weight: .regular)
            let rowPadV: CGFloat = 12
            var prevHadDrawer = false

            for i in 0..<a.choices.count {
                if i > 0 {
                    let full = prevHadDrawer
                    dividers.append(AskCardGeometry.Divider(
                        frame: CGRect(x: full ? side : x, y: y, width: full ? cardW : (cardW - padH), height: 0),
                        fullWidth: full
                    ))
                }
                prevHadDrawer = false

                let rowTop = y
                let displayTitle = AskCards.choiceTitle(a.choices[i])
                let isPicked = card.picked == i
                let isRec = a.recommended == i
                let hasReply = AskCards.reply(a, index: i) != nil
                let showPreviewCue = hasAnyReply && hasReply && !isPicked
                let whyText = (isRec && !a.why.isEmpty) ? a.why : ""

                let titleFont = isPicked ? pickedFont : rowFont
                let titleColor = isPicked ? ChatPalette.tintText : ChatPalette.label

                var tagFrame: CGRect?
                var tagTextLayout: TextKitLayout?
                var cueTextLayout: TextKitLayout?
                var cueInline = false
                var tagInline = false
                var checkFrame: CGRect?

                let singleTitleW = ceil((displayTitle as NSString).size(withAttributes: [.font: titleFont]).width)
                var titleMaxW = innerW

                if isPicked {
                    titleMaxW = max(60, innerW - 24)
                } else if isRec {
                    let tl = TextKitLayout(PromptLayout.text("Recommended", tagFont, ChatPalette.decisionTagFg), width: nil)
                    tagTextLayout = tl
                    let pillW = ceil(tl.size.width) + 16
                    if !category.isAccessibilityCategory, singleTitleW + 10 + pillW <= innerW {
                        tagInline = true
                        titleMaxW = max(60, innerW - pillW - 10)
                    }
                } else if showPreviewCue {
                    let cl = TextKitLayout(PromptLayout.text("Preview reply", cueFont, ChatPalette.label3), width: nil)
                    cueTextLayout = cl
                    let cueW = ceil(cl.size.width)
                    if !category.isAccessibilityCategory, singleTitleW + 10 + cueW <= innerW {
                        cueInline = true
                        titleMaxW = max(60, innerW - cueW - 10)
                    }
                }

                let titleLayout = TextKitLayout(PromptLayout.text(displayTitle, titleFont, titleColor), width: titleMaxW)
                var contentH = titleLayout.size.height

                var stackedTagOffsetY: CGFloat?
                var stackedCueOffsetY: CGFloat?
                if let tl = tagTextLayout, !tagInline {
                    stackedTagOffsetY = contentH + 5
                    contentH += 5 + ceil(tl.size.height) + 6
                } else if let cl = cueTextLayout, !cueInline {
                    stackedCueOffsetY = contentH + 3
                    contentH += 3 + ceil(cl.size.height)
                }

                var whyLayout: TextKitLayout?
                var whyOffsetY: CGFloat = 0
                if !whyText.isEmpty {
                    let wl = TextKitLayout(PromptLayout.text(whyText, whyFont, ChatPalette.label2), width: innerW)
                    whyLayout = wl
                    whyOffsetY = contentH + 4
                    contentH += 4 + wl.size.height
                }

                let rowH = max(46, ceil(contentH) + 2 * rowPadV)
                let startY = rowTop + ((rowH - contentH) / 2).rounded()

                texts.append(PromptPlacedText(
                    text: titleLayout,
                    frame: CGRect(x: x, y: startY, width: titleMaxW, height: titleLayout.size.height)
                ))

                if isPicked {
                    let checkSide: CGFloat = 15
                    let firstLineMidY = startY + min(titleLayout.size.height, ceil(titleFont.lineHeight)) / 2
                    checkFrame = CGRect(x: x + innerW - checkSide, y: (firstLineMidY - checkSide / 2).rounded(),
                                        width: checkSide, height: checkSide)
                } else if let tl = tagTextLayout {
                    let pillW = ceil(tl.size.width) + 16
                    let pillH = ceil(tl.size.height) + 6
                    let pillRect: CGRect
                    if tagInline {
                        let firstLineMidY = startY + min(titleLayout.size.height, ceil(titleFont.lineHeight)) / 2
                        pillRect = CGRect(x: x + innerW - pillW, y: (firstLineMidY - pillH / 2).rounded(),
                                          width: pillW, height: pillH)
                    } else {
                        pillRect = CGRect(x: x, y: startY + (stackedTagOffsetY ?? 0), width: pillW, height: pillH)
                    }
                    tagFrame = pillRect
                    texts.append(PromptPlacedText(
                        text: tl,
                        frame: CGRect(x: pillRect.minX + 8, y: pillRect.minY + ((pillH - tl.size.height) / 2).rounded(),
                                      width: tl.size.width, height: tl.size.height)
                    ))
                } else if let cl = cueTextLayout {
                    if cueInline {
                        let firstLineMidY = startY + min(titleLayout.size.height, ceil(titleFont.lineHeight)) / 2
                        texts.append(PromptPlacedText(
                            text: cl,
                            frame: CGRect(x: x + innerW - cl.size.width, y: (firstLineMidY - cl.size.height / 2).rounded(),
                                          width: cl.size.width, height: cl.size.height)
                        ))
                    } else {
                        texts.append(PromptPlacedText(
                            text: cl,
                            frame: CGRect(x: x, y: startY + (stackedCueOffsetY ?? 0),
                                          width: cl.size.width, height: cl.size.height)
                        ))
                    }
                }

                if let wl = whyLayout {
                    texts.append(PromptPlacedText(
                        text: wl,
                        frame: CGRect(x: x, y: startY + whyOffsetY, width: innerW, height: wl.size.height)
                    ))
                }

                let rowFrame = CGRect(x: side, y: rowTop, width: cardW, height: rowH)
                placed.append((i, rowFrame))
                choiceRows.append(AskCardGeometry.ChoiceRow(
                    index: i,
                    frame: rowFrame,
                    title: displayTitle,
                    isPicked: isPicked,
                    isRecommended: isRec,
                    hasReply: hasReply,
                    why: whyText,
                    tagFrame: tagFrame,
                    checkFrame: checkFrame,
                    roundBottom: false
                ))
                y = rowTop + rowH

                // [asks v2] Inline accordion ready-reply drawer directly underneath the picked choice!
                if isPicked, let reply = card.reply, let to = a.replyTo {
                    let bandTop = rowTop
                    block = replyBlock(card, reply: reply, to: to, x: x, y: &y, innerW: innerW,
                                       category: category, texts: &texts, spoken: &spoken)
                    pickedBand = CGRect(x: side, y: bandTop, width: cardW, height: y - bandTop)
                    prevHadDrawer = true
                }
            }

            spoken.append("Choices: " + a.choices.map(AskCards.choiceTitle).joined(separator: ", "))
            if let picked = card.picked, a.choices.indices.contains(picked) {
                spoken.append("Picked: " + AskCards.choiceTitle(a.choices[picked]))
            }

            // "Something else…" bottom row aligned to the exact same left spine, with trailing pencil glyph.
            let fullBeforeOther = prevHadDrawer
            dividers.append(AskCardGeometry.Divider(
                frame: CGRect(x: fullBeforeOther ? side : x, y: y, width: fullBeforeOther ? cardW : (cardW - padH), height: 0),
                fullWidth: fullBeforeOther
            ))
            let otherTop = y
            let otherFont = font(.callout, category, weight: .regular)
            let pencilSide: CGFloat = ceil(min(18, max(14, otherFont.pointSize * 0.88)))
            let otherMaxW = max(60, innerW - pencilSide - 10)
            let o = TextKitLayout(PromptLayout.text(otherTitle, otherFont, ChatPalette.label2), width: otherMaxW)
            let otherH = max(46, ceil(o.size.height) + 24)
            let oFrame = CGRect(x: x, y: otherTop + ((otherH - o.size.height) / 2).rounded(),
                                width: min(otherMaxW, ceil(o.size.width)), height: o.size.height)
            texts.append(PromptPlacedText(text: o, frame: oFrame))
            otherPencilFrame = CGRect(x: x + innerW - pencilSide,
                                      y: otherTop + ((otherH - pencilSide) / 2).rounded(),
                                      width: pencilSide, height: pencilSide)
            otherFrame = CGRect(x: side, y: otherTop, width: cardW, height: otherH)
            otherVisual = otherFrame
            y = otherTop + otherH
        }

        let cardFrame = CGRect(x: side, y: top, width: cardW, height: ceil(y - top))
        let accessibility = spoken.joined(separator: ". ")
        var geometry = AskCardGeometry(
            buttons: placed,
            choiceRows: choiceRows,
            titles: a.choices.map(AskCards.choiceTitle),
            font: btnFont,
            stacked: true,
            other: otherFrame,
            otherVisual: otherVisual,
            otherPencilFrame: otherPencilFrame,
            link: linkFrame,
            linkGlyphFrame: linkGlyphFrame,
            linkTitle: linkTitle,
            brandFrame: brandFrame,
            brandSpec: brandSpec,
            quote: quoteRect,
            quoteToggle: quoteToggleRect,
            quoteToggleTitle: quoteToggleTitle,
            chips: chips,
            dividers: dividers,
            disabled: card.answering || card.editingReply
        )
        geometry.picked = card.picked
        geometry.pickedBand = pickedBand
        if let override = toggleOverride {
            geometry.toggleFrame = override.frame
            geometry.toggleLabel = override.label
            geometry.toggleExpanded = override.expanded
            geometry.backingFrame = backingFrame
        } else if card.answer != nil {
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
        }
        var layout = PromptRowLayout(cardFrame: cardFrame, texts: texts, approval: nil, symbols: symbols, rules: [],
                                     accessibility: accessibility)
        layout.ask = geometry
        // Generous bottom clearance (+10 pt) so soft light-mode card shadows never clip against cell bounds.
        return RowLayout(height: ceil(cardFrame.maxY + 10), content: .prompt(layout))
    }

    /// Calm compact receipt for an answered ask card; shows real brand icon + honest delivery status, expands on tap.
    private static func makeReceipt(_ card: AskCardRow, answer: AskCards.Answer, gap: CGFloat, width: CGFloat,
                                    category: UIContentSizeCategory) -> RowLayout {
        let a = card.ask
        let cardW = PromptLayout.cardWidth(for: width)
        let padX: CGFloat = 14, padY: CGFloat = 11
        let innerW = cardW - 2 * padX
        let top = max(0, gap) + 6, x = side + padX

        let brandSpec = a.hasExternalSource ? AppBrandResolver.resolve(ask: a) : nil
        let headFont = font(.subheadline, category, weight: .semibold, cap: 24)
        let subFont = font(.footnote, category, weight: .regular, cap: 22)
        let mark = ceil(min(26, max(20, headFont.pointSize * 1.35)))
        let chevW = ceil(min(16, max(12, headFont.pointSize * 0.8)))

        let receiptTitle = AskCards.receiptTitle(a, answer, delivery: card.delivery)
        let titleLead: String = {
            if brandSpec != nil {
                return card.delivery == .sent ? "✓  \(receiptTitle)" : receiptTitle
            }
            return receiptTitle
        }()
        let titleColor: UIColor = card.delivery == .failed ? ChatPalette.red : ChatPalette.label

        let titleX = x + mark + 10
        let titleW = max(60, innerW - mark - 10 - chevW - 8)
        let (headText, _) = PromptLayout.clamped(
            PromptLayout.text(titleLead, headFont, titleColor),
            width: titleW,
            maxLines: category.isAccessibilityCategory ? 2 : 1
        )
        let headY = top + padY
        let firstH = max(brandSpec != nil ? mark : ceil(headFont.lineHeight), headText.size.height)

        var symbols: [PromptSymbol] = []
        var brandFrame: CGRect?
        if brandSpec != nil {
            brandFrame = CGRect(x: x, y: headY + ((firstH - mark) / 2).rounded(), width: mark, height: mark)
        } else {
            let iconSide = ceil(min(20, max(16, headFont.pointSize * 1.1)))
            let (iconName, iconStyle): (String, PromptSymbol.Style) = {
                switch card.delivery {
                case .sent: ("checkmark", .quiet)
                case .sending, .queued: ("clock", .quiet)
                case .failed: ("exclamationmark.circle", .dim)
                }
            }()
            symbols.append(PromptSymbol(
                frame: CGRect(x: x + ((mark - iconSide) / 2).rounded(),
                              y: headY + ((firstH - iconSide) / 2).rounded(),
                              width: iconSide, height: iconSide),
                name: iconName, style: iconStyle
            ))
        }
        let chevSymbol = PromptSymbol(
            frame: CGRect(x: x + innerW - chevW, y: headY + ((firstH - chevW) / 2).rounded(), width: chevW, height: chevW),
            name: "chevron.down", style: .blank
        )
        symbols.append(chevSymbol)

        var texts = [PromptPlacedText(
            text: headText,
            frame: CGRect(x: titleX, y: headY + ((firstH - headText.size.height) / 2).rounded(),
                          width: headText.size.width, height: headText.size.height)
        )]
        var y = headY + firstH + 3

        let statusSpoken = AskCards.status(a, answer)
        var spoken = [source(a, category: category).1, a.question].filter { !$0.isEmpty }
        let previewText: String
        let previewLines: Int
        if case .sent(_, _, let reply) = answer, !reply.isEmpty {
            previewText = reply
            previewLines = min(2, PromptRows.askSentLines)
            spoken.append(reply)
        } else {
            let suffix = [a.app.isEmpty ? nil : a.app, a.from.isEmpty ? nil : a.from].compactMap { $0 }.joined(separator: " · ")
            previewText = suffix.isEmpty ? a.question : "\(a.question) · \(suffix)"
            previewLines = 1
        }
        spoken.append(statusSpoken)

        let previewW = max(60, innerW - mark - 10 - chevW - 4)
        let (preview, _) = PromptLayout.clamped(PromptLayout.text(previewText, subFont, ChatPalette.label2),
                                                width: previewW, maxLines: previewLines)
        texts.append(PromptPlacedText(text: preview, frame: CGRect(x: titleX, y: y, width: previewW, height: preview.size.height)))
        y += preview.size.height

        let cardFrame = CGRect(x: side, y: top, width: cardW, height: ceil(y + padY - top))
        let accessibility = spoken.joined(separator: ". ")
        var geometry = AskCardGeometry(buttons: [], titles: a.choices.map(AskCards.choiceTitle), font: PromptFonts.button(category),
                                       stacked: false, other: nil, link: nil, linkTitle: "",
                                       brandFrame: brandFrame, brandSpec: brandSpec, quote: nil, chips: [], disabled: false)
        geometry.toggleFrame = cardFrame
        geometry.toggleLabel = accessibility
        geometry.toggleExpanded = false
        var layout = PromptRowLayout(cardFrame: cardFrame, texts: texts, approval: nil, symbols: symbols,
                                     rules: [], accessibility: accessibility)
        layout.ask = geometry
        return RowLayout(height: ceil(cardFrame.maxY + 8), content: .prompt(layout))
    }

    /// Quiet one-line disclosure for an unanswered ask left behind by later conversation.
    /// Tapping opens the full interactive Concept 1 card below it so the user can still answer it inline!
    private static func makeFolded(_ card: AskCardRow, gap: CGFloat, width: CGFloat, category: UIContentSizeCategory) -> RowLayout {
        let a = card.ask
        let cardW = PromptLayout.cardWidth(for: width)
        let f = font(.footnote, category, cap: 22)
        let strongFont = font(.footnote, category, weight: .semibold, cap: 22)
        let iconSide = ceil(min(22, max(16, f.pointSize * 1.15)))
        let chevW = ceil(min(18, max(11, f.pointSize * 0.85)))
        let rowH = max(32, ceil(f.lineHeight) + 10)
        let top = max(0, gap)

        let flatQ = a.question.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        let label = NSMutableAttributedString(attributedString: PromptLayout.text(flatQ, strongFont, ChatPalette.label2))
        label.append(PromptLayout.text(" · Unanswered", f, ChatPalette.label3))

        let textX = side + iconSide + 7
        let maxTextW = max(60, cardW - iconSide - 7 - 6 - chevW)
        let (lineLayout, _) = PromptLayout.clamped(label, width: maxTextW, maxLines: 1)
        let lineY = top + ((rowH - lineLayout.size.height) / 2).rounded()
        let textFrame = CGRect(x: textX, y: lineY, width: lineLayout.size.width, height: lineLayout.size.height)
        let leadFrame = CGRect(x: side, y: top + ((rowH - iconSide) / 2).rounded(), width: iconSide, height: iconSide)
        let collapsedBrand = a.hasExternalSource ? AppBrandResolver.resolve(ask: a) : nil
        let chevSymbol = PromptSymbol(frame: CGRect(x: textFrame.maxX + 6, y: top + ((rowH - chevW) / 2).rounded(), width: chevW, height: chevW),
                                      name: card.expanded ? "chevron.up" : "chevron.down", style: .blank)
        let rowWidth = min(cardW, chevSymbol.frame.maxX - side)
        let tapH = max(44, rowH)
        let toggleFrame = CGRect(x: side - 6, y: top + (rowH - tapH) / 2, width: rowWidth + 12, height: tapH)
        let pillH = min(rowH, ceil(max(f.lineHeight, iconSide)) + 8)
        let backingFrame = CGRect(x: side - 8, y: top + ((rowH - pillH) / 2).rounded(), width: rowWidth + 16, height: pillH)
        let accessibility = [source(a, category: category).1, a.question, "Unanswered"].filter { !$0.isEmpty }.joined(separator: ". ")

        guard card.expanded else {
            var symbols: [PromptSymbol] = []
            if collapsedBrand == nil {
                symbols.append(PromptSymbol(frame: leadFrame, name: AskCards.quietGlyph(a), style: .quiet))
            }
            symbols.append(chevSymbol)
            var geometry = AskCardGeometry(buttons: [], titles: a.choices.map(AskCards.choiceTitle), font: PromptFonts.button(category),
                                           stacked: false, other: nil, link: nil, linkTitle: "",
                                           brandFrame: collapsedBrand != nil ? leadFrame : nil,
                                           brandSpec: collapsedBrand, quote: nil, chips: [], disabled: false)
            geometry.toggleFrame = toggleFrame
            geometry.toggleLabel = accessibility
            geometry.toggleExpanded = false
            geometry.backingFrame = backingFrame
            var layout = PromptRowLayout(cardFrame: nil, texts: [PromptPlacedText(text: lineLayout, frame: textFrame)],
                                         approval: nil, symbols: symbols, rules: [], accessibility: accessibility)
            layout.ask = geometry
            return RowLayout(height: ceil(top + rowH + 2), content: .prompt(layout))
        }

        // Expanded stale fold: collapse bar at top + full interactive Concept 1 card directly below!
        let leadSymbol = PromptSymbol(frame: leadFrame, name: AskCards.quietGlyph(a), style: .quiet)
        return makeCard(
            card,
            top: top + rowH + 6,
            width: width,
            category: category,
            leadingTexts: [PromptPlacedText(text: lineLayout, frame: textFrame)],
            leadingSymbols: [leadSymbol, chevSymbol],
            toggleOverride: (frame: toggleFrame, label: accessibility, expanded: true),
            backingFrame: backingFrame
        )
    }

    /// [asks v2] Inline accordion ready-reply block placed directly underneath the picked choice row.
    struct ReplyBlock {
        var paper: CGRect
        var buttons: [(DraftButton, CGRect)]
        var stacked: Bool
        var showAll: CGRect?
        var showAllTitle: String
    }

    static func replyBlock(_ card: AskCardRow, reply: String, to: AskCards.ReplyTo, x: CGFloat, y: inout CGFloat, innerW: CGFloat,
                           category: UIContentSizeCategory, texts: inout [PromptPlacedText], spoken: inout [String]) -> ReplyBlock {
        y -= 2
        let headFont = font(.footnote, category, weight: .semibold, cap: 22)
        let heading = AskCards.replyHeading(to) + (card.edited ? " · Edited" : "")
        let (h, _) = PromptLayout.clamped(PromptLayout.text(heading, headFont, ChatPalette.label2), width: innerW, maxLines: 2)
        texts.append(PromptPlacedText(text: h, frame: CGRect(x: x, y: y, width: innerW, height: h.size.height)))
        y += h.size.height

        if !to.subject.isEmpty {
            y += 3
            let subjFont = font(.footnote, category, weight: .medium, cap: 22)
            let (subj, _) = PromptLayout.clamped(PromptLayout.text("Subject: \(to.subject)", subjFont, ChatPalette.label2),
                                                 width: innerW, maxLines: 2)
            texts.append(PromptPlacedText(text: subj, frame: CGRect(x: x, y: y, width: innerW, height: subj.size.height)))
            y += subj.size.height
        }

        y += 8
        let paperTop = y
        let paperPadH: CGFloat = 12, paperPadV: CGFloat = 10
        let wx = x + paperPadH
        let wordsW = max(60, innerW - 2 * paperPadH)
        y += paperPadV
        let replyFont = font(.subheadline, category)
        let (words, cut) = PromptLayout.clamped(
            PromptLayout.text(reply, replyFont, ChatPalette.label),
            width: wordsW,
            maxLines: card.replyExpanded ? 0 : PromptRows.askReplyLines
        )
        texts.append(PromptPlacedText(text: words, frame: CGRect(x: wx, y: y, width: wordsW, height: words.size.height)))
        y += words.size.height
        spoken.append(AskCards.replySpoken(to, reply) + (card.edited ? " (edited)" : ""))

        var showAll: CGRect?
        let showAllTitle = card.replyExpanded ? "Show Less" : "Show All"
        if cut || (card.replyExpanded && PromptLayout.lineCount(words) > PromptRows.askReplyLines) {
            let moreFont = font(.footnote, category, weight: .medium, cap: 22)
            let more = TextKitLayout(linkText(showAllTitle, moreFont, ChatPalette.tintText), width: nil)
            let frame = CGRect(x: wx, y: y + 6, width: more.size.width, height: more.size.height)
            texts.append(PromptPlacedText(text: more, frame: frame))
            showAll = frame.insetBy(dx: -8, dy: -max(0, (44 - frame.height) / 2))
            y = frame.maxY
        }
        y += paperPadV
        let paper = CGRect(x: x, y: paperTop, width: innerW, height: max(1, y - paperTop))

        y += 10
        // Edit (plain) and Send (tinted capsule — the ONLY filled accent button in the card).
        let btnFont = PromptFonts.button(category)
        let order: [DraftButton] = [.edit, .send]
        let bh = max(44, ceil(btnFont.lineHeight) + 16)
        let widths = order.map { ceil((PromptLayout.draftButtonTitle($0) as NSString).size(withAttributes: [.font: btnFont]).width) + 32 }
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
        y += 12
        return ReplyBlock(paper: paper, buttons: placed, stacked: stacked, showAll: showAll, showAllTitle: showAllTitle)
    }
}

// MARK: - Interactive Choice Row Control

/// Full-width tappable action row inside an Ask card: instant crisp press wash, iPad + Mac hover, optional
/// layout-drawn `Recommended` pill background, and optional v2 picked checkmark.
private final class AskActionRowControl: UIControl {
    private let highlightView = UIView()
    private let tagPill = UIView()
    private let trailingIcon = UIImageView()
    private var roundsBottom = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        highlightView.isUserInteractionEnabled = false
        highlightView.alpha = 0
        highlightView.layer.cornerCurve = .continuous
        addSubview(highlightView)

        tagPill.isUserInteractionEnabled = false
        tagPill.isHidden = true
        tagPill.layer.cornerRadius = 7
        tagPill.layer.cornerCurve = .continuous
        addSubview(tagPill)

        trailingIcon.isUserInteractionEnabled = false
        trailingIcon.isHidden = true
        trailingIcon.contentMode = .scaleAspectFit
        addSubview(trailingIcon)

        isAccessibilityElement = true
        accessibilityTraits = .button
        PointerEffects.surface(self)
        if UIDevice.current.userInterfaceIdiom == .pad {
            addInteraction(UIPointerInteraction(delegate: RowHoverPointer.shared))
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (view: AskActionRowControl, _) in
            view.recolor()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            let target: CGFloat = isHighlighted && isEnabled ? 1 : 0
            if isHighlighted {
                highlightView.layer.removeAllAnimations()
                highlightView.alpha = target
            } else {
                UIView.animate(withDuration: 0.16, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {   // motion-ok: opacity only
                    self.highlightView.alpha = target
                }
            }
        }
    }

    func configure(
        frame: CGRect,
        cardFrame: CGRect?,
        roundBottom: Bool,
        tagFrameInRow: CGRect?,
        iconFrameInRow: CGRect?,
        iconName: String?,
        iconWeight: UIImage.SymbolWeight = .regular,
        iconTint: UIColor = ChatPalette.label3
    ) {
        self.frame = frame
        self.roundsBottom = roundBottom
        highlightView.frame = bounds
        if roundBottom {
            highlightView.layer.cornerRadius = ChatMetrics.insetCardRadius
            highlightView.layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        } else {
            highlightView.layer.cornerRadius = 0
            highlightView.layer.maskedCorners = []
        }

        if let tf = tagFrameInRow {
            tagPill.isHidden = false
            tagPill.frame = tf.offsetBy(dx: -frame.minX, dy: -frame.minY)
        } else {
            tagPill.isHidden = true
        }

        if let icf = iconFrameInRow, let iconName {
            trailingIcon.isHidden = false
            trailingIcon.frame = icf.offsetBy(dx: -frame.minX, dy: -frame.minY)
            trailingIcon.tintColor = iconTint
            let cfg = UIImage.SymbolConfiguration(pointSize: icf.height * 0.92, weight: iconWeight)
            trailingIcon.image = UIImage(systemName: iconName, withConfiguration: cfg)
        } else {
            trailingIcon.isHidden = true
        }

        if let cardFrame {
            PointerEffects.fit(self, card: cardFrame, radius: ChatMetrics.insetCardRadius)
        }
        recolor()
    }

    func recolor() {
        highlightView.backgroundColor = ChatPalette.fill3.resolvedColor(with: traitCollection)
        tagPill.backgroundColor = ChatPalette.decisionTagBg.resolvedColor(with: traitCollection)
    }
}

private final class RowHoverPointer: NSObject, UIPointerInteractionDelegate {
    static let shared = RowHoverPointer()

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        guard let view = interaction.view, view.window != nil else { return nil }
        return UIPointerStyle(effect: .hover(UITargetedPreview(view: view), preferredTintMode: .overlay,
                                             prefersShadow: false, prefersScaledContent: false))
    }
}

// MARK: - View

/// Interactive overlay and decorative shapes for Concept 1 Ask cards: brand icon tile, hairlines, quote bar,
/// borderless attachment chips, full-width wrapping choice rows, v2 inline reply paper & buttons, and "Something else…".
final class AskCardView: UIView {
    var onChoice: ((Int) -> Void)?
    var onOther: (() -> Void)?
    var onLink: (() -> Void)?
    var onQuoteToggle: (() -> Void)?
    var onReply: ((DraftButton) -> Void)?
    var onShowAll: (() -> Void)?
    var onToggle: (() -> Void)?

    private var choiceControls: [AskActionRowControl] = []
    private var replyButtons: [DraftButton: UIButton] = [:]
    private let otherRow = AskActionRowControl()
    private let showAll = UIControl()
    private let quoteToggle = UIControl()
    private let link = UIControl()
    private let linkGlyph = UIImageView()
    private let toggle = UIControl()
    private let brandTile = AppBrandTileView()
    private let bar = UIView()
    private let paperView = UIView()
    private let pickedBandView = UIView()
    private var dividerViews: [UIView] = []
    private var chipViews: [(UIView, UIImageView)] = []

    /// VoiceOver focus order after the card summary itself.
    private(set) var ordered: [UIView] = []

    override init(frame: CGRect) {
        super.init(frame: frame)

        pickedBandView.isUserInteractionEnabled = false
        pickedBandView.isHidden = true
        addSubview(pickedBandView)

        paperView.isUserInteractionEnabled = false
        paperView.isHidden = true
        paperView.layer.cornerRadius = HQShape.radius(10, .card)
        paperView.layer.cornerCurve = .continuous
        addSubview(paperView)

        bar.isUserInteractionEnabled = false
        bar.layer.cornerRadius = 1
        addSubview(bar)

        brandTile.isHidden = true
        addSubview(brandTile)

        toggle.isHidden = true
        toggle.isAccessibilityElement = true
        toggle.accessibilityTraits = .button
        toggle.accessibilityIdentifier = "ask.toggle"
        toggle.addAction(UIAction { [weak self] _ in self?.onToggle?() }, for: .touchUpInside)
        addSubview(toggle)
        PointerEffects.surface(toggle)

        otherRow.accessibilityIdentifier = "ask.other"
        otherRow.accessibilityLabel = AskCardLayout.otherTitle
        otherRow.accessibilityHint = "Write a custom reply"
        otherRow.addAction(UIAction { [weak self] _ in self?.onOther?() }, for: .touchUpInside)
        addSubview(otherRow)

        linkGlyph.isUserInteractionEnabled = false
        linkGlyph.isHidden = true
        linkGlyph.contentMode = .scaleAspectFit
        addSubview(linkGlyph)

        for (control, id, label) in [
            (link, "ask.link", ""),
            (quoteToggle, "ask.quoteToggle", "More"),
            (showAll, "ask.showAll", "Show All")
        ] {
            control.isAccessibilityElement = true
            control.accessibilityTraits = .button
            control.accessibilityIdentifier = id
            control.accessibilityLabel = label
            addSubview(control)
            PointerEffects.outline(control) { [weak control] in
                guard let box = control?.bounds, box.width > 0, box.height > 0 else { return nil }
                let h = min(box.height, 26)
                let rect = CGRect(x: 0, y: ((box.height - h) / 2).rounded(), width: box.width, height: h)
                return PointerEffects.Outline(rect: rect, radius: HQShape.radius(6, .control), strong: false)
            }
        }
        link.accessibilityTraits = .link
        link.addAction(UIAction { [weak self] _ in self?.onLink?() }, for: .touchUpInside)
        quoteToggle.addAction(UIAction { [weak self] _ in self?.onQuoteToggle?() }, for: .touchUpInside)
        showAll.addAction(UIAction { [weak self] _ in self?.onShowAll?() }, for: .touchUpInside)

        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (view: AskCardView, _) in
            view.recolor()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func cancelLoads() {
        brandTile.cancel()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    func configure(_ g: AskCardGeometry, cardFrame: CGRect? = nil) {
        // Brand icon tile
        if let bf = g.brandFrame, let spec = g.brandSpec {
            brandTile.frame = bf
            brandTile.configure(spec)
        } else {
            brandTile.configure(nil)
        }

        // Picked band & v2 reply paper
        pickedBandView.isHidden = g.pickedBand == nil
        pickedBandView.frame = g.pickedBand ?? .zero

        paperView.isHidden = g.paper == nil
        paperView.frame = g.paper ?? .zero

        // Quote vertical bar & More/Show less toggle
        bar.isHidden = g.quote == nil
        bar.frame = g.quote ?? .zero

        quoteToggle.isHidden = g.quoteToggle == nil
        quoteToggle.frame = g.quoteToggle ?? .zero
        quoteToggle.accessibilityLabel = g.quoteToggleTitle
        PointerEffects.outlineDidLayout(quoteToggle)

        // Hairline dividers
        let hair = HQShape.pixel(traitCollection.displayScale)
        while dividerViews.count < g.dividers.count {
            let v = UIView()
            v.isUserInteractionEnabled = false
            addSubview(v)
            dividerViews.append(v)
        }
        for (i, v) in dividerViews.enumerated() {
            guard i < g.dividers.count else { v.isHidden = true; continue }
            v.isHidden = false
            let d = g.dividers[i].frame
            v.frame = CGRect(x: d.minX, y: d.minY, width: d.width, height: hair)
        }

        // Borderless `fill4` attachment chips
        while chipViews.count < g.chips.count {
            let chip = UIView()
            chip.isUserInteractionEnabled = false
            chip.layer.cornerCurve = .continuous
            chip.layer.cornerRadius = 8
            let icon = UIImageView(image: UIImage(systemName: "paperclip"))
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
            icon.frame = g.chips[i].icon
            icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: icon.frame.height * 0.85, weight: .medium)
        }

        ordered = []

        // Disclosure / receipt collapse toggle
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

        // Link (trailing header `↗` or body link on expanded receipt)
        if let frame = g.link {
            link.isHidden = false
            link.frame = frame
            link.accessibilityLabel = g.linkTitle.replacingOccurrences(of: " ↗", with: "")
            PointerEffects.outlineDidLayout(link)
            ordered.append(link)
        } else {
            link.isHidden = true
        }
        if let gf = g.linkGlyphFrame {
            linkGlyph.isHidden = false
            linkGlyph.frame = gf
            let cfg = UIImage.SymbolConfiguration(pointSize: gf.height * 0.85, weight: .medium)
            linkGlyph.image = UIImage(systemName: "arrow.up.right", withConfiguration: cfg)
        } else {
            linkGlyph.isHidden = true
        }

        if g.quoteToggle != nil { ordered.append(quoteToggle) }

        // Choice rows (and inline v2 reply controls right after the picked choice in VoiceOver order!)
        while choiceControls.count < g.choiceRows.count {
            choiceControls.append(makeChoiceControl(choiceControls.count))
        }
        for (i, control) in choiceControls.enumerated() {
            guard i < g.choiceRows.count else { control.isHidden = true; continue }
            let spec = g.choiceRows[i]
            control.isHidden = false
            control.isEnabled = !g.disabled
            control.configure(
                frame: spec.frame,
                cardFrame: cardFrame,
                roundBottom: spec.roundBottom,
                tagFrameInRow: spec.tagFrame,
                iconFrameInRow: spec.checkFrame,
                iconName: spec.isPicked ? "checkmark" : nil,
                iconWeight: .semibold,
                iconTint: ChatPalette.tintText
            )
            var labelParts = [spec.title]
            if spec.isRecommended { labelParts.append("Recommended") }
            if !spec.why.isEmpty { labelParts.append(spec.why) }
            control.accessibilityLabel = labelParts.joined(separator: ", ")
            control.accessibilityTraits = spec.isPicked ? [.button, .selected] : .button
            if spec.hasReply {
                control.accessibilityHint = spec.isPicked ? "Hides reply preview" : "Shows reply before sending"
            } else {
                control.accessibilityHint = "Sends your answer"
            }
            ordered.append(control)

            // Place inline accordion controls right after their owning choice in VoiceOver order.
            if spec.isPicked {
                if g.showAll != nil { ordered.append(showAll) }
                for (kind, _) in g.replyButtons {
                    if let btn = replyButtons[kind] { ordered.append(btn) }
                }
            }
        }

        // v2 Show All & Edit/Send buttons
        showAll.isHidden = g.showAll == nil
        showAll.frame = g.showAll ?? .zero
        showAll.accessibilityLabel = g.showAllTitle
        PointerEffects.outlineDidLayout(showAll)

        var shownReply = Set<DraftButton>()
        for (kind, frame) in g.replyButtons {
            let button = replyButtons[kind] ?? makeReply(kind)
            button.isHidden = false
            button.frame = frame
            button.configuration = replyConfig(kind, font: g.font)
            button.isEnabled = !g.disabled
            shownReply.insert(kind)
            if !ordered.contains(button) { ordered.append(button) }
        }
        for (kind, button) in replyButtons where !shownReply.contains(kind) { button.isHidden = true }

        // "Something else…" bottom row
        if let frame = g.other {
            otherRow.isHidden = false
            otherRow.isEnabled = !g.disabled
            otherRow.configure(
                frame: frame,
                cardFrame: cardFrame,
                roundBottom: true,
                tagFrameInRow: nil,
                iconFrameInRow: g.otherPencilFrame,
                iconName: "pencil",
                iconWeight: .regular,
                iconTint: ChatPalette.label3
            )
            ordered.append(otherRow)
        } else {
            otherRow.isHidden = true
        }

        recolor()
    }

    private func recolor() {
        let dark = traitCollection.userInterfaceStyle == .dark
        bar.backgroundColor = ChatPalette.separator.resolvedColor(with: traitCollection)
        paperView.backgroundColor = ChatPalette.fill4.resolvedColor(with: traitCollection)
        pickedBandView.backgroundColor = ChatPalette.tint.resolvedColor(with: traitCollection).withAlphaComponent(dark ? 0.10 : 0.045)
        linkGlyph.tintColor = ChatPalette.label3
        let divColor = ChatPalette.decisionEdge.resolvedColor(with: traitCollection)
        for v in dividerViews { v.backgroundColor = divColor }
        let chipBg = ChatPalette.fill4.resolvedColor(with: traitCollection)
        for (chip, icon) in chipViews {
            chip.backgroundColor = chipBg
            chip.layer.borderWidth = 0
            icon.tintColor = ChatPalette.label2
        }
        for c in choiceControls where !c.isHidden { c.recolor() }
        otherRow.recolor()
    }

    private func makeChoiceControl(_ index: Int) -> AskActionRowControl {
        let control = AskActionRowControl()
        control.accessibilityIdentifier = "ask.choice.\(index + 1)"
        control.addAction(UIAction { [weak self] _ in self?.onChoice?(index) }, for: .touchUpInside)
        addSubview(control)
        return control
    }

    private func makeReply(_ kind: DraftButton) -> UIButton {
        let button = UIButton(type: .system)
        button.accessibilityIdentifier = "ask.reply.\(kind)"
        button.addAction(UIAction { [weak self] _ in self?.onReply?(kind) }, for: .primaryActionTriggered)
        addSubview(button)
        PointerEffects.button(button)
        replyButtons[kind] = button
        return button
    }

    /// Edit is plain secondary text; Send is the ONLY filled tinted capsule in the card.
    private func replyConfig(_ kind: DraftButton, font: UIFont) -> UIButton.Configuration {
        var c: UIButton.Configuration
        switch kind {
        case .send:
            c = .filled()
            c.baseBackgroundColor = ChatPalette.tint
            c.baseForegroundColor = ChatPalette.onTint
        case .edit, .skip:
            c = .plain()
            c.baseForegroundColor = ChatPalette.label2
        }
        c.cornerStyle = .capsule
        c.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
        c.title = PromptLayout.draftButtonTitle(kind)
        c.titleLineBreakMode = .byTruncatingTail
        c.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in var a = a; a.font = font; return a }
        return c
    }
}
