import UIKit

// The transcript's prompt rows (spec 1x §4.2, §4.4): the approval card at the newest end, and the clarify note in
// place of the running clarify tool part (asked → sent answers → settled Q&A). Pure value types, built and measured
// on any thread like every other row (ChatRow.swift, TextLayout.swift: hooks marked [questions]).

// MARK: - Rows

/// What the chat screen hands the row builder (`ChatRowBuilder.Input.prompts`).
nonisolated struct PromptRowsInput: Sendable, Equatable {
    var approval: ApprovalCardRow?
    var clarifyNote: ClarifyNote?
    /// True while `QuestionDockView` is expanded on screen for the open clarify prompt: suppresses the duplicate
    /// `"A question for you"` transcript card above the dock while still marking the turn as waiting on the user.
    var clarifyDockExpanded: Bool = false

    var hidesAskedNote: Bool {
        if clarifyDockExpanded, case .asked? = clarifyNote { return true }
        return false
    }
}

nonisolated enum ClarifyNote: Sendable, Equatable, Hashable {
    /// "A question for you" / "N questions for you" + the questions (shown in place when the dock is minimized).
    /// [groups] `asker`: in a room, the member who asks ("Ivy asks").
    case asked(count: Int, first: String, asker: String? = nil, questions: [String] = [])
    case undelivered
    case sent([SentClarifyRow])
}

/// A clarify call's settled card: its questions and answers (answers given later in the chat filled in), and whether a
/// question still waits for one ("Answer Now").
nonisolated struct SettledClarifyCard: Sendable, Equatable, Hashable {
    var rows: [ClarifyQA]
    /// `ClarifyLate.key` of its questions: what the later answer's message names.
    var key: String
    var messageId: String
    /// The questions (on one line) that took several picks, read from the call's arguments.
    var multi: Set<String> = []
    /// A question has no answer, and none came later: the card offers Answer Now.
    var answerable: Bool
    /// An answer came later, in the chat.
    var answeredLater: Bool
    /// [calm-chat] Row id for tap-to-expand toggle (`<messageId>|q<callId>`).
    var rowId: String = ""
    /// [calm-chat] Quiet one-line receipt/disclosure once answered or left behind by later turns.
    var folded: Bool = false
    var expanded: Bool = false
    /// [calm-chat] Unanswered question left behind by later human turns (drops live Answer Now pill).
    var staleUnanswered: Bool = false

    var isQuietFolded: Bool { folded && !expanded }
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
    /// [v0.23.4] Sandbox approval card kind and fields (`access` / `network`).
    var kind: ApprovalKind = .command
    var path: String? = nil
    var access: ApprovalAccessLevel? = nil
    var host: String? = nil
    var label: String? = nil
    var risk: String? = nil
}

nonisolated struct PromptRow: Sendable {
    enum Kind: Sendable {
        case approval(ApprovalCardRow)
        case note(ClarifyNote)
        case settled(SettledClarifyCard)
        /// [drafts] A bot's draft for review: its text, Send, Edit and Don't Send (HermesKit/Drafts/DraftCards.swift).
        case draft(DraftCardRow)
        /// [shopping] A bot's product cards and its order card (HermesKit/Shopping/ShoppingCards.swift, App/Shopping).
        case products(ProductsCardRow)
        case order(OrderCardRow)
        /// [travel] A bot's flight and hotel cards (HermesKit/Travel/TravelCards.swift, App/Travel).
        case flights(FlightsCardRow)
        case hotels(HotelsCardRow)
        /// [asks] A bot asks before it acts for you: the question, its choices, Something else (App/Asks).
        case ask(AskCardRow)
    }
    var kind: Kind
}

nonisolated enum PromptRows {
    /// The message id of rows drawn after the newest message (ChatRowModel rebuilds them with the newest end).
    static let tailMessageId = "prompts"
    static let commandClampLines = 8
    static let foldedQuestionClampLines = 6
    static let foldedAnswerClampLines = 2

    /// The rows after the newest message: the approval card, and the question note when no running clarify part
    /// holds it (a reopened chat).
    static func tail(_ input: ChatRowBuilder.Input) -> [ChatRow] {
        guard let prompts = input.prompts else { return [] }
        var rows: [ChatRow] = []
        if let note = prompts.clarifyNote, !prompts.hidesAskedNote, runningClarifyId(input.messages) == nil {
            rows.append(row(id: "\(tailMessageId)|note", messageId: tailMessageId, kind: .note(note), scope: input.scope))
        }
        if let approval = prompts.approval {
            rows.append(row(id: "\(tailMessageId)|approval", messageId: tailMessageId, kind: .approval(approval), scope: input.scope))
        }
        return rows
    }

    /// True when the running clarify tool part is already represented on screen by the expanded `QuestionDockView`
    /// (so neither a duplicate `"A question for you"` card nor a generic tool step row should steal transcript space).
    static func hidesRunningClarify(_ call: ToolCall, input: ChatRowBuilder.Input) -> Bool {
        guard call.name == "clarify", call.state == .running,
              input.prompts?.hidesAskedNote == true,
              runningClarifyId(input.messages) == call.id else { return false }
        return true
    }

    /// A clarify tool part's row: the note while it runs (and a note exists), the settled card once its result has
    /// `responses`, else nil (the generic tool row).
    static func clarifyRow(_ call: ToolCall, message: ChatMessage, input: ChatRowBuilder.Input) -> ChatRow? {
        guard call.name == "clarify" else { return nil }
        let id = "\(message.id)|q\(call.id)"
        if call.state == .running {
            guard let note = input.prompts?.clarifyNote, !hidesRunningClarify(call, input: input),
                  runningClarifyId(input.messages) == call.id else { return nil }
            return row(id: id, messageId: message.id, kind: .note(note), scope: input.scope)
        }
        guard let rows = ClarifySettled.rows(fromSummary: call.summary), !rows.isEmpty else { return nil }
        return row(id: id, messageId: message.id, kind: .settled(settledCard(rows, call: call, message: message, input: input)),
                   scope: input.scope)
    }

    /// The settled card: answers you gave later in the chat (after this message) fill its blanks; a blank left over
    /// offers Answer Now until later human turns move past it (not in a room, whose sends go to its members).
    static func settledCard(_ rows: [ClarifyQA], call: ToolCall, message: ChatMessage, input: ChatRowBuilder.Input) -> SettledClarifyCard {
        let key = ClarifyLate.key(rows.map(\.question))
        var found = input.clarifyLate[key]
        if let f = found, f.index != .max, let at = input.messages.lastIndex(where: { $0.id == message.id }), f.index < at { found = nil }
        let (shown, later) = ClarifyLate.filled(rows, found)
        let blank = shown.contains { $0.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let rowId = "\(message.id)|q\(call.id)"
        let staleUnanswered = blank && ClarifyLate.hasLaterHumanTurn(after: message.id, in: input.messages)
        let movedPastTurn = !blank && ClarifyLate.hasMovedPastTurn(after: message.id, answeredAt: found?.index, in: input.messages)
        let folded = staleUnanswered || movedPastTurn
        return SettledClarifyCard(rows: shown, key: key, messageId: message.id, multi: multiSelect(call.argsText),
                                  answerable: blank && input.room == nil && !staleUnanswered, answeredLater: later,
                                  rowId: rowId, folded: folded, expanded: input.expanded.contains(rowId),
                                  staleUnanswered: staleUnanswered)
    }

    /// The questions (on one line) the call asked as multi-select.
    static func multiSelect(_ argsText: String?) -> Set<String> {
        guard let argsText, argsText.contains("multi_select"), let data = argsText.data(using: .utf8),
              let args = try? JSONValue.parseFast(data) else { return [] }
        var out = Set<String>()
        for q in args["questions"]?.array ?? [] where q["multi_select"]?.bool == true {
            if let text = q["question"]?.string { out.insert(ClarifyLate.flat(text)) }
        }
        return out
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

    static func row(id: String, messageId: String, kind: PromptRow.Kind, scope: String) -> ChatRow {
        var h = Hasher()
        switch kind {
        case .approval(let a): h.combine(0); h.combine(a)
        case .note(let n): h.combine(1); h.combine(n)
        case .settled(let card): h.combine(2); h.combine(card)
        case .draft(let d): h.combine(3); h.combine(d)
        case .products(let p): h.combine(4); h.combine(p)   // [shopping]
        case .order(let o): h.combine(5); h.combine(o)
        case .ask(let a): h.combine(6); h.combine(a)   // [asks]
        case .flights(let f): h.combine(7); h.combine(f)   // [travel]
        case .hotels(let ht): h.combine(8); h.combine(ht)   // [travel]
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
    /// disc with a white glyph (a card's header mark when nothing was chosen); `quiet` plain monochrome label-2;
    /// `success` green disc with contrasting checkmark for settled receipts.
    enum Style: Sendable { case header, picked, blank, dim, quiet, success }
}

/// [calm-chat] Tap target + frosted backing for a folded settled clarify disclosure row.
nonisolated struct PromptFoldToggle: Sendable, Equatable {
    var rowId: String
    var frame: CGRect
    var label: String
    var expanded: Bool
    var backingFrame: CGRect?
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
    /// [shopping] The product cards' or the order card's own drawing (App/Shopping).
    var shopping: ShoppingRowLayout? = nil
    /// [travel] The flight or hotel cards' own drawing (App/Travel).
    var travel: TravelRowLayout? = nil
    /// [asks] The ask card's buttons, links, bar and chips (App/Asks/AskCardView.swift).
    var ask: AskCardGeometry? = nil
    /// [calm-chat] Tap-to-expand toggle for a folded settled clarify card.
    var foldToggle: PromptFoldToggle? = nil
    /// VoiceOver's reading of the whole card.
    var accessibility: String
    /// A settled question card's Answer Now button (a question went without an answer), in row coordinates.
    var answerNow: CGRect? = nil
    var answerNowFont: UIFont? = nil
}

nonisolated enum PromptFonts {
    private static func traits(_ c: UIContentSizeCategory) -> UITraitCollection { UITraitCollection(preferredContentSizeCategory: c) }

    static func font(_ style: UIFont.TextStyle, _ category: UIContentSizeCategory, weight: UIFont.Weight? = nil,
                     cap: CGFloat? = nil) -> UIFont {
        let base = HQFont.preferred(style, compatibleWith: traits(category))
        let size = cap.map { min($0, base.pointSize) } ?? base.pointSize
        if let weight { return HQFont.face(ofSize: size, weight: weight) }
        if cap != nil { return HQFont.face(ofSize: size, weight: style == .headline ? .semibold : .regular) }
        return base
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
    /// [calm-chat] Wide panes (Mac, iPad) keep interactive cards on a calm left-anchored rail instead of stretching
    /// edge-to-edge across the full 1280 pt Mac column. Narrow phones keep `width - 2 * cardSide`.
    static var maxCardWidth: CGFloat { DeviceWord.isMac ? 660 : 560 }

    static func cardWidth(for width: CGFloat) -> CGFloat {
        let available = max(120, width - 2 * cardSide)
        return min(available, min(TextLayout.replyWidth(width), maxCardWidth))
    }

    static func make(_ prompt: PromptRow, row: ChatRow, width: CGFloat, style: ChatStyle) -> RowLayout {
        switch prompt.kind {
        case .approval(let a): return approval(a, gap: row.gapAbove, width: width, category: style.category)
        case .note(let n): return note(n, gap: row.gapAbove, width: width, category: style.category)
        case .settled(let card): return settled(card, gap: row.gapAbove, width: width, category: style.category)
        case .draft(let d): return draft(d, gap: row.gapAbove, width: width, category: style.category)
        case .products(let p): return ProductCardsLayout.make(p, gap: row.gapAbove, width: width, category: style.category)   // [shopping]
        case .order(let o): return OrderCardLayout.make(o, gap: row.gapAbove, width: width, category: style.category)
        case .flights(let f): return FlightsCardLayout.make(f, gap: row.gapAbove, width: width, category: style.category)   // [travel]
        case .hotels(let h): return HotelsCardLayout.make(h, gap: row.gapAbove, width: width, category: style.category)
        case .ask(let a): return AskCardLayout.make(a, gap: row.gapAbove, width: width, category: style.category)   // [asks]
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
        switch a.kind {
        case .access:
            if let asker = a.asker, !asker.isEmpty { return "\(asker) needs folder access" }
            return "Folder access needed"
        case .network:
            if let asker = a.asker, !asker.isEmpty { return "\(asker) needs website access" }
            return "Website access needed"
        case .command:
            // [groups] A room names the member whose turn waits (docs/spec/3x-groups.md §7.10).
            if let asker = a.asker, !asker.isEmpty {
                let first = a.command.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
                if first.isEmpty { return "\(asker) needs your approval" }
                return "\(asker) wants to run: \(first.count > 60 ? String(first.prefix(60)) + "…" : first)"
            }
            return "Approval needed"
        }
    }

    static func approvalGlyph(_ kind: ApprovalKind) -> String {
        switch kind {
        case .command: "apple.terminal.circle.fill"
        case .access: "folder.circle.fill"
        case .network: "globe"
        }
    }

    static func approvalMetaLabel(_ a: ApprovalCardRow) -> String {
        switch a.kind {
        case .access:
            switch a.access {
            case .readWrite: "Read & write access"
            case .read: "Read-only access"
            case nil: "Folder access"
            }
        case .network: "Website"
        case .command: a.showsDescription ? "Command details" : "Command"
        }
    }

    static func approvalDetails(_ a: ApprovalCardRow) -> String {
        switch a.kind {
        case .access:
            return (a.path ?? a.description).trimmingCharacters(in: .whitespacesAndNewlines)
        case .network:
            let host = (a.host ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let label = (a.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !label.isEmpty && !host.isEmpty && label.caseInsensitiveCompare(host) != .orderedSame {
                return "\(label)\n\(host)"
            }
            return (!label.isEmpty ? label : host)
        case .command:
            return (a.showsDescription ? a.description : a.command).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Under an expired card: whom to ask names the bot (or, in a room, the member whose turn asked).
    static func expiredNote(_ a: ApprovalCardRow) -> String {
        let who = [a.asker, a.botName].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        return "This request expired. Ask \(who ?? "the bot") to try again."
    }

    static func buttonTitle(_ button: ApprovalButton, approvalKind: ApprovalKind = .command) -> String {
        switch button {
        case .reject: approvalKind == .command ? "Reject" : "Deny"
        case .dismiss: "Dismiss"
        case .more: "More…"
        case .session: "Allow for This Chat"
        case .always: "Always Allow…"
        case .run: approvalKind == .command ? "Run" : "Allow"
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
        let cardW = cardWidth(for: width)
        let innerX = notePadH
        let innerW = cardW - 2 * innerX
        var texts: [PromptPlacedText] = []
        let cardTop = gap + 6

        // Every card's header: round mark (terminal / folder / globe, grey once expired) and title.
        let head = noteHeader(approvalTitle(a), glyph: approvalGlyph(a.kind), dim: a.expired, x: side + innerX, y: cardTop + notePadV,
                              width: innerW, category: category)
        texts.append(head.text)

        // The line under it: "Command" / "Read-only access" / "Website", "1 / 2", the expiry (trailing, updated in place).
        var cy: CGFloat = head.maxY - cardTop + 10
        let footnote = PromptFonts.font(.footnote, category)
        // The header line is meta: capped at 24 pt so "Command" and the countdown stay readable at AX sizes.
        let meta = PromptFonts.font(.footnote, category, cap: 24)
        let lineH = ceil(meta.lineHeight)
        let metaText = approvalMetaLabel(a)
        let label = TextKitLayout(text(metaText, meta, ChatPalette.label2), width: innerW)
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

        // The command/path/website (monospaced for commands and folder paths, ≤ 8 lines), on an inset panel.
        let details = approvalDetails(a)
        var showAllFrame: CGRect?
        var paper: CGRect?
        if !details.isEmpty {
            let pad: CGFloat = 12, wordsX = innerX + pad, wordsW = innerW - 2 * pad
            let paperTop = cy
            cy += pad
            let font = (a.showsDescription || a.kind == .network) ? footnote : PromptFonts.mono(category)
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
        // The risk line (sandbox cards) or reason under a shown command.
        let reason = (a.risk ?? a.description).trimmingCharacters(in: .whitespacesAndNewlines)
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

        // Actions: one trailing row, or full-width stacked (Run/Allow first) at accessibility sizes or when they don't fit.
        let font = PromptFonts.button(category)
        let order = buttons(a)
        let h = max(44, ceil(font.lineHeight) + 16)
        func titleWidth(_ b: ApprovalButton) -> CGFloat {
            let titleW = ceil((buttonTitle(b, approvalKind: a.kind) as NSString).size(withAttributes: [.font: font]).width)
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
        let spoken = [approvalTitle(a), "\(metaText): \(details)",
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
        case .asked(let count, let first, let asker, let questions):
            var title = count > 1 ? "\(count) questions for you" : "A question for you"
            if let asker, !asker.isEmpty { title = count > 1 ? "\(asker) has \(count) questions for you" : "\(asker) asks" }   // [groups]
            let full = questions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let detail = full.isEmpty ? first : full.joined(separator: "\n\n")
            return noteCard(title: title, glyph: "questionmark.circle.fill", detail: detail, detailColor: ChatPalette.label,
                            gap: gap, width: width, category: category, detailLines: 8)
        case .undelivered:
            return noteCard(title: "A question for you", glyph: "exclamationmark.circle.fill",
                            detail: "This question didn’t reach the app, so it can’t be answered here. Press Stop to end the turn, then reply in chat.",
                            detailColor: ChatPalette.label2, gap: gap, width: width, category: category, detailLines: 0)
        case .sent(let rows):
            return qa(rows.map { ($0.question, $0.answer.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? "", $0.answer == nil) },
                      gap: gap, width: width, category: category)
        }
    }

    static func settled(_ card: SettledClarifyCard, gap: CGFloat, width: CGFloat, category: UIContentSizeCategory) -> RowLayout {
        let title = card.answeredLater ? (card.rows.count == 1 ? "Answered later" : "Your answers, some later") : nil
        if card.folded {
            if card.expanded {
                return qa(card.rows.map { ($0.question, $0.answer.trimmingCharacters(in: .whitespacesAndNewlines), $0.unanswered) },
                          gap: gap, width: width, category: category, answerNow: card.answerable,
                          title: title, collapseRowId: card.rowId)
            }
            return settledFolded(card, gap: gap, width: width, category: category)
        }
        return qa(card.rows.map { ($0.question, $0.answer.trimmingCharacters(in: .whitespacesAndNewlines), $0.unanswered) },
                  gap: gap, width: width, category: category, answerNow: card.answerable, title: title)
    }

    /// [calm-chat] Quiet compact disclosure for settled clarify Q&A cards once a later human turn moves past them.
    /// Questions always lead so they are never cut off behind the answer: a short Q&A that fits on one line stays
    /// one line ("Which branch? · main"); longer questions wrap naturally with the answer beneath them.
    private static func settledFolded(_ card: SettledClarifyCard, gap: CGFloat, width: CGFloat, category: UIContentSizeCategory) -> RowLayout {
        let side = cardSide
        let cardW = cardWidth(for: width)
        let font = PromptFonts.font(.footnote, category, cap: 22)
        let strongFont = PromptFonts.font(.footnote, category, weight: .semibold, cap: 22)
        let lineH = ceil(font.lineHeight)
        let iconSide = ceil(min(22, max(15, font.pointSize * 1.1)))
        let chevW = ceil(min(18, max(11, font.pointSize * 0.85)))
        let top = max(0, gap)

        let answeredRows = card.rows.filter { !$0.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let allSkipped = answeredRows.isEmpty
        let textX = side + iconSide + 7
        let maxTextW = max(60, cardW - iconSide - 7 - 6 - chevW)

        struct Block {
            var question: TextKitLayout
            var answer: TextKitLayout?
        }
        var blocks: [Block] = []
        blocks.reserveCapacity(card.rows.count)
        for r in card.rows {
            let qFlat = ClarifyLate.flat(r.question)
            let ans = r.answer.trimmingCharacters(in: .whitespacesAndNewlines)
            let isBlank = ans.isEmpty
            let ansWords = isBlank ? (r.unanswered ? "No answer" : "Skipped") : ans
            let ansColor = isBlank ? ChatPalette.label2 : ChatPalette.label

            if !category.isAccessibilityCategory {
                let inline = NSMutableAttributedString(attributedString: text(qFlat, font, ChatPalette.label2))
                inline.append(text(" · ", font, ChatPalette.label3))
                inline.append(text(ansWords, strongFont, ansColor))
                let inlineLayout = TextKitLayout(inline, width: maxTextW)
                if lineCount(inlineLayout) <= 1 {
                    blocks.append(Block(question: inlineLayout, answer: nil))
                    continue
                }
            }
            let (qLayout, _) = clamped(text(qFlat, font, ChatPalette.label2), width: maxTextW,
                                       maxLines: PromptRows.foldedQuestionClampLines)
            let (aLayout, _) = clamped(text(ansWords, strongFont, ansColor), width: maxTextW,
                                       maxLines: PromptRows.foldedAnswerClampLines)
            blocks.append(Block(question: qLayout, answer: aLayout))
        }

        let singleInline = blocks.count == 1 && blocks[0].answer == nil && lineCount(blocks[0].question) <= 1
        var texts: [PromptPlacedText] = []
        let rowH: CGFloat
        let leadY: CGFloat
        let chevY: CGFloat
        var widestText: CGFloat = 0

        if singleInline, let only = blocks.first {
            let singleH = max(32, ceil(only.question.size.height) + 10)
            let lineY = top + ((singleH - only.question.size.height) / 2).rounded()
            texts.append(PromptPlacedText(text: only.question,
                                          frame: CGRect(x: textX, y: lineY, width: only.question.size.width, height: only.question.size.height)))
            widestText = only.question.size.width
            rowH = singleH
            leadY = top + ((singleH - iconSide) / 2).rounded()
            chevY = top + ((singleH - chevW) / 2).rounded()
        } else {
            let padV: CGFloat = 6
            let firstLineH = max(lineH, iconSide)
            var y = top + padV + max(0, (iconSide - lineH) / 2).rounded()
            for (idx, block) in blocks.enumerated() {
                if idx > 0 { y += 6 }
                texts.append(PromptPlacedText(text: block.question,
                                              frame: CGRect(x: textX, y: y, width: block.question.size.width, height: block.question.size.height)))
                widestText = max(widestText, block.question.size.width)
                y += block.question.size.height
                if let ans = block.answer {
                    y += 2
                    texts.append(PromptPlacedText(text: ans,
                                                  frame: CGRect(x: textX, y: y, width: ans.size.width, height: ans.size.height)))
                    widestText = max(widestText, ans.size.width)
                    y += ans.size.height
                }
            }
            leadY = top + padV + max(0, (lineH - iconSide) / 2).rounded()
            chevY = top + padV + ((firstLineH - chevW) / 2).rounded()
            let bottom = max(leadY + iconSide, y) + padV
            rowH = max(32, ceil(bottom - top))
        }

        let leadSymbol = PromptSymbol(
            frame: CGRect(x: side, y: leadY, width: iconSide, height: iconSide),
            name: allSkipped ? "minus.circle" : "checkmark.circle.fill",
            style: allSkipped ? .blank : .success
        )
        let chevX = min(side + cardW - chevW, textX + widestText + 6)
        let chevSymbol = PromptSymbol(
            frame: CGRect(x: chevX, y: chevY, width: chevW, height: chevW),
            name: "chevron.down",
            style: .blank
        )
        let rowWidth = min(cardW, chevSymbol.frame.maxX - side)
        let tapH = max(44, rowH)
        let toggleFrame = CGRect(x: side - 6, y: top + (rowH - tapH) / 2, width: rowWidth + 12, height: tapH)
        let pillH = singleInline ? min(rowH, ceil(max(lineH, iconSide)) + 8) : max(24, rowH - 2)
        let backingFrame = CGRect(x: side - 8, y: top + ((rowH - pillH) / 2).rounded(), width: rowWidth + 16, height: pillH)

        let spokenLead: String = {
            if allSkipped { return card.rows.count == 1 ? "Question skipped" : "\(card.rows.count) questions skipped" }
            return card.rows.count == 1 ? "Answered question" : "Answered \(answeredRows.count) questions"
        }()
        let spoken = card.rows.map { r -> String in
            let ans = r.answer.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(r.question): \(ans.isEmpty ? (r.unanswered ? "No answer" : "Skipped") : ans)"
        }.joined(separator: ". ")
        let accessibility = "\(spokenLead). \(spoken)"
        let toggle = PromptFoldToggle(rowId: card.rowId, frame: toggleFrame, label: accessibility, expanded: false,
                                      backingFrame: backingFrame)
        var layout = PromptRowLayout(cardFrame: nil, texts: texts, approval: nil,
                                     symbols: [leadSymbol, chevSymbol], rules: [], accessibility: accessibility)
        layout.foldToggle = toggle
        return RowLayout(height: ceil(top + rowH + 2), content: .prompt(layout))
    }

    static let answerNowTitle = "Answer Now"

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
        let cardW = cardWidth(for: width), innerW = cardW - 2 * notePadH
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
    /// `answerNow`: a trailing Answer Now button under the questions (a question left without an answer).
    private static func qa(_ rows: [(question: String, answer: String, unanswered: Bool)], gap: CGFloat, width: CGFloat,
                           category: UIContentSizeCategory, answerNow: Bool = false, title shownTitle: String? = nil,
                           collapseRowId: String? = nil) -> RowLayout {
        let side = cardSide
        let cardW = cardWidth(for: width), innerW = cardW - 2 * notePadH
        let top = max(0, gap) + 6, x = side + notePadH
        var (title, glyph) = answersTitle(rows)
        if let shownTitle { title = shownTitle }
        let headFont = PromptFonts.font(.subheadline, category, weight: .semibold, cap: 26)
        let chevW: CGFloat = collapseRowId != nil ? ceil(min(18, max(12, headFont.pointSize * 0.8))) : 0
        let headW = chevW > 0 ? max(60, innerW - chevW - 8) : innerW
        let head = noteHeader(title, glyph: glyph, dim: glyph.hasPrefix("minus"), x: x, y: top + notePadV, width: headW, category: category)
        var texts = [head.text]
        var symbols = [head.symbol]
        if chevW > 0 {
            let headH = head.maxY - (top + notePadV)
            symbols.append(PromptSymbol(frame: CGRect(x: x + innerW - chevW, y: top + notePadV + ((headH - chevW) / 2).rounded(), width: chevW, height: chevW),
                                        name: "chevron.up", style: .blank))
        }
        var rules: [CGRect] = []
        var spoken: [String] = []
        let answerFont = PromptFonts.font(.body, category, weight: .semibold)
        let blankFont = PromptFonts.italic(.body, category)
        let mark = ceil(min(28, max(18, answerFont.pointSize * 1.06)))
        let answerX = x + mark + 8
        var y = head.maxY + noteHeaderGap + 2
        var lastLine: (midY: CGFloat, right: CGFloat, blank: Bool)?   // the last answer's first line, for Answer Now
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
            lastLine = (y + first / 2, answerX + a.size.width, blank && a.size.height <= lineH * 1.5)
            y += max(a.size.height + (first - lineH) / 2, first)
            spoken.append("\(row.question): \(words)")
        }
        var answerFrame: CGRect?
        let buttonFont = PromptFonts.button(category)
        if answerNow {
            // One trailing capsule, as a draft card's Send; full width at accessibility sizes.
            let h = max(44, ceil(buttonFont.lineHeight) + 16)
            let w = min(innerW, ceil((answerNowTitle as NSString).size(withAttributes: [.font: buttonFont]).width) + 32)
            if let line = lastLine, line.blank, !category.isAccessibilityCategory, line.right + 16 + w <= x + innerW {
                // Beside the last "No answer" (owner: no wasted space), centred on its line.
                // Shorter than the row's own button, so it stays clear of the question above.
                let inlineH = ceil(buttonFont.lineHeight) + 10
                let frame = CGRect(x: x + innerW - w, y: (line.midY - inlineH / 2).rounded(), width: w, height: inlineH)
                answerFrame = frame
                y = max(y, frame.maxY - 4)
            } else {
                y += 12
                answerFrame = category.isAccessibilityCategory ? CGRect(x: x, y: y, width: innerW, height: h)
                    : CGRect(x: x + innerW - w, y: y, width: w, height: h)
                y += h
            }
        }
        let card = CGRect(x: side, y: top, width: cardW, height: ceil(y + notePadV - top))
        let accessibility = ([title] + spoken).joined(separator: ". ")
        var layout = PromptRowLayout(
            cardFrame: card, texts: texts, approval: nil, symbols: symbols, rules: rules,
            accessibility: accessibility, answerNow: answerFrame, answerNowFont: buttonFont)
        if let collapseRowId {
            let headerBandH = max(44, head.maxY - top + notePadV)
            layout.foldToggle = PromptFoldToggle(rowId: collapseRowId,
                                                 frame: CGRect(x: side, y: top, width: cardW, height: headerBandH),
                                                 label: accessibility, expanded: true, backingFrame: nil)
        }
        return RowLayout(height: ceil(card.maxY + 6), content: .prompt(layout))
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
    /// [calm-chat] Draft row ids superseded by a later draft to the same destination; nil computes from `messages`.
    var superseded: Set<String>? = nil
    /// [calm-chat] Draft row ids left unanswered after 2+ later human turns; nil computes from `messages`.
    var stale: Set<String>? = nil
}

nonisolated enum DraftButton: Sendable, Hashable { case skip, edit, send }

nonisolated struct DraftCardRow: Sendable, Equatable, Hashable {
    enum State: Sendable, Hashable { case waiting, sent, skipped, superseded, stale }
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
    /// Show All was tapped (waiting), or the folded receipt / superseded row was expanded.
    var expanded: Bool

    /// [calm-chat] Collapsed quiet one-line disclosure row (no heavy card chrome).
    var isQuietFolded: Bool { (state == .superseded || state == .skipped || state == .stale) && !expanded }
}

nonisolated struct DraftCardLayout: @unchecked Sendable {
    var showAllFrame: CGRect?
    var showAllTitle: String
    var buttons: [(DraftButton, CGRect)]
    var buttonFont: UIFont
    var stacked: Bool
    /// The draft body region in row coordinates (drawn cleanly with `bodyBar` instead of a nested bordered box).
    var paper: CGRect
    /// [calm-chat] Left vertical accent bar beside the draft body (or stem aligned under the receipt checkmark).
    var bodyBar: CGRect? = nil
    /// [calm-chat] True for an active waiting draft's tint accent bar; false for settled/folded separator bar.
    var bodyBarTint = false
    /// [calm-chat] Subtle divider above the waiting draft's action row.
    var footerDivider: CGRect? = nil
    /// [calm-chat] Tap target that toggles folding/expansion on settled or superseded drafts.
    var toggleFrame: CGRect? = nil
    var toggleLabel = ""
    var toggleExpanded = false
    /// [calm-chat] Pill frame for `placeBacking` over a Chat Background when collapsed without a card (`cardFrame == nil`).
    var backingFrame: CGRect? = nil
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
        let id = DraftCards.rowId(messageId: message.id, callId: call.id)
        var card = DraftCardRow(draft: draft, rowId: id, messageId: message.id, body: draft.body, edited: false, state: .waiting,
                                editing: input.drafts.editing == draft.id, expanded: input.expanded.contains(id))
        switch input.drafts.answers[draft.id] {
        case .send(let body):
            card.state = .sent
            if let body { card.body = body }
        case .skip:
            card.state = .skipped
        case nil:
            let superseded = input.drafts.superseded ?? DraftCards.supersededRowIds(input.messages)
            let stale = input.drafts.stale ?? DraftCards.staleRowIds(input.messages)
            if superseded.contains(id) {
                card.state = .superseded
            } else if stale.contains(id) {
                card.state = .stale
            } else if let edit = input.drafts.edits[draft.id] {
                card.body = edit
            }
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

    /// The status wording for a settled or superseded draft.
    static func draftStatus(_ d: DraftCardRow) -> String? {
        switch d.state {
        case .waiting: nil
        case .sent: d.edited ? "Approved to send, with your edits" : "Approved to send"
        case .skipped: "Not sent"
        case .superseded: "Revised below"
        case .stale: "Left unsent"
        }
    }

    /// [calm-chat] The draft card:
    /// - `.superseded` / `.skipped` / `.stale`: quiet one-line disclosure row (no live buttons); tap expands read-only text.
    /// - `.sent`: compact two-line receipt card with a quoted preview stem; tap expands full text.
    /// - `.waiting`: clean single-surface card on the readable rail with left tint bar and trailing action row.
    static func draft(_ d: DraftCardRow, gap: CGFloat, width: CGFloat, category: UIContentSizeCategory) -> RowLayout {
        switch d.state {
        case .superseded, .skipped, .stale:
            return draftFolded(d, gap: gap, width: width, category: category)
        case .sent:
            return draftReceipt(d, gap: gap, width: width, category: category)
        case .waiting:
            return draftWaiting(d, gap: gap, width: width, category: category)
        }
    }

    /// Quiet one-line disclosure for superseded or skipped drafts; tapping opens a muted read-only drawer below it.
    private static func draftFolded(_ d: DraftCardRow, gap: CGFloat, width: CGFloat, category: UIContentSizeCategory) -> RowLayout {
        let side = cardSide
        let cardW = cardWidth(for: width)
        let status = draftStatus(d) ?? "Not sent"
        let font = PromptFonts.font(.footnote, category, cap: 22)
        let strongFont = PromptFonts.font(.footnote, category, weight: .semibold, cap: 22)
        let iconSide = ceil(min(22, max(15, font.pointSize * 1.1)))
        let chevW = ceil(min(18, max(11, font.pointSize * 0.85)))
        let rowH = max(32, ceil(font.lineHeight) + 10)
        let top = max(0, gap)

        let label = NSMutableAttributedString(attributedString: text(DraftCards.heading(d.draft), strongFont, ChatPalette.label2))
        var tail = ""
        if !d.draft.to.isEmpty { tail += " to \(d.draft.to)" }
        tail += " · \(status)"
        label.append(text(tail, font, ChatPalette.label2))

        let textX = side + iconSide + 7
        let maxTextW = max(60, cardW - iconSide - 7 - 6 - chevW)
        let (lineLayout, _) = clamped(label, width: maxTextW, maxLines: 1)
        let lineY = top + ((rowH - lineLayout.size.height) / 2).rounded()
        let textFrame = CGRect(x: textX, y: lineY, width: lineLayout.size.width, height: lineLayout.size.height)
        let leadSymbol = PromptSymbol(
            frame: CGRect(x: side, y: top + ((rowH - iconSide) / 2).rounded(), width: iconSide, height: iconSide),
            name: d.state == .skipped ? "minus.circle" : DraftCards.quietGlyph(d.draft),
            style: d.state == .skipped ? .blank : .quiet
        )
        let chevSymbol = PromptSymbol(
            frame: CGRect(x: textFrame.maxX + 6, y: top + ((rowH - chevW) / 2).rounded(), width: chevW, height: chevW),
            name: d.expanded ? "chevron.up" : "chevron.down",
            style: .blank
        )
        let rowWidth = min(cardW, chevSymbol.frame.maxX - side)
        let tapH = max(44, rowH)
        let toggleFrame = CGRect(x: side - 6, y: top + (rowH - tapH) / 2, width: rowWidth + 12, height: tapH)
        let pillH = min(rowH, ceil(max(font.lineHeight, iconSide)) + 8)
        let backingFrame = CGRect(x: side - 8, y: top + ((rowH - pillH) / 2).rounded(), width: rowWidth + 16, height: pillH)

        var spoken = [DraftCards.heading(d.draft)]
        if !d.draft.to.isEmpty { spoken.append("To: \(d.draft.to)") }
        if d.expanded { spoken.append(d.body) }
        spoken.append(status)
        let accessibility = spoken.joined(separator: ". ")

        guard d.expanded else {
            var draft = DraftCardLayout(showAllFrame: nil, showAllTitle: "", buttons: [], buttonFont: PromptFonts.button(category),
                                        stacked: false, paper: .zero)
            draft.toggleFrame = toggleFrame
            draft.toggleLabel = accessibility
            draft.toggleExpanded = false
            draft.backingFrame = backingFrame
            var layout = PromptRowLayout(cardFrame: nil, texts: [PromptPlacedText(text: lineLayout, frame: textFrame)],
                                         approval: nil, symbols: [leadSymbol, chevSymbol], rules: [], accessibility: accessibility)
            layout.draft = draft
            return RowLayout(height: ceil(top + rowH + 2), content: .prompt(layout))
        }

        // Expanded read-only drawer card right below the quiet toggle line.
        let innerW = cardW - 2 * notePadH
        let cardTop = top + rowH + 4
        let x = side + notePadH
        var y = cardTop + notePadV
        var texts = [PromptPlacedText(text: lineLayout, frame: textFrame)]
        let symbols = [leadSymbol, chevSymbol]
        let fields = DraftCards.fields(d.draft)
        if !fields.isEmpty {
            let metaFont = PromptFonts.font(.footnote, category)
            let metaLine = fields.map { "\($0.label): \($0.value)" }.joined(separator: "  ·  ")
            let (meta, _) = clamped(text(metaLine, metaFont, ChatPalette.label2), width: innerW, maxLines: 2)
            texts.append(PromptPlacedText(text: meta, frame: CGRect(x: x, y: y, width: innerW, height: meta.size.height)))
            y += meta.size.height + 8
        }
        let barX = x + 2
        let wx = x + 14, wordsW = max(60, innerW - 14)
        let paperTop = y
        let bodyText = text(d.body, PromptFonts.font(.subheadline, category), ChatPalette.label2)
        let body = TextKitLayout(bodyText, width: wordsW)
        texts.append(PromptPlacedText(text: body, frame: CGRect(x: wx, y: y, width: wordsW, height: body.size.height)))
        y += body.size.height
        let paper = CGRect(x: x, y: paperTop, width: innerW, height: max(1, y - paperTop))
        let bodyBar = CGRect(x: barX, y: paperTop + 1, width: 2, height: max(10, body.size.height - 2))
        let card = CGRect(x: side, y: cardTop, width: cardW, height: ceil(y + notePadV - cardTop))

        var draft = DraftCardLayout(showAllFrame: nil, showAllTitle: "", buttons: [], buttonFont: PromptFonts.button(category),
                                    stacked: false, paper: paper)
        draft.bodyBar = bodyBar
        draft.bodyBarTint = false
        draft.toggleFrame = toggleFrame
        draft.toggleLabel = accessibility
        draft.toggleExpanded = true
        draft.backingFrame = backingFrame
        var layout = PromptRowLayout(cardFrame: card, texts: texts, approval: nil, symbols: symbols, rules: [], accessibility: accessibility)
        layout.draft = draft
        return RowLayout(height: ceil(card.maxY + 4), content: .prompt(layout))
    }

    /// Compact two-line receipt card for approved/sent drafts; tapping expands to the full sent message.
    private static func draftReceipt(_ d: DraftCardRow, gap: CGFloat, width: CGFloat, category: UIContentSizeCategory) -> RowLayout {
        let side = cardSide
        let cardW = cardWidth(for: width), innerW = cardW - 2 * notePadH
        let padV: CGFloat = 11
        let top = max(0, gap) + 4, x = side + notePadH
        let status = draftStatus(d) ?? "Approved to send"
        let headFont = PromptFonts.font(.subheadline, category, weight: .semibold, cap: 24)
        let subFont = PromptFonts.font(.subheadline, category, cap: 24)
        let mark = ceil(min(24, max(17, headFont.pointSize * 1.15)))
        let chevW = ceil(min(18, max(12, headFont.pointSize * 0.8)))

        let headingLead: String = {
            if !d.draft.to.isEmpty {
                return d.edited ? "Approved to send (edited) · \(d.draft.to)" : "Approved to send to \(d.draft.to)"
            }
            return status
        }()
        let headAttr = NSMutableAttributedString(attributedString: text(headingLead, headFont, ChatPalette.label))
        headAttr.append(text("  ·  \(DraftCards.name(d.draft))", subFont, ChatPalette.label2))

        let titleX = x + mark + 8
        let titleW = max(60, innerW - mark - 8 - chevW - 8)
        let (headText, _) = clamped(headAttr, width: titleW, maxLines: category.isAccessibilityCategory ? 2 : 1)
        let headY = top + padV
        let firstH = max(mark, headText.size.height)
        let checkSymbol = PromptSymbol(
            frame: CGRect(x: x, y: headY + ((firstH - mark) / 2).rounded(), width: mark, height: mark),
            name: "checkmark.circle.fill",
            style: .success
        )
        let chevSymbol = PromptSymbol(
            frame: CGRect(x: x + innerW - chevW, y: headY + ((firstH - chevW) / 2).rounded(), width: chevW, height: chevW),
            name: d.expanded ? "chevron.up" : "chevron.down",
            style: .blank
        )
        var texts = [PromptPlacedText(text: headText, frame: CGRect(x: titleX, y: headY + ((firstH - headText.size.height) / 2).rounded(),
                                                                    width: headText.size.width, height: headText.size.height))]
        let symbols = [checkSymbol, chevSymbol]
        var spoken = [DraftCards.heading(d.draft)]
        for field in DraftCards.fields(d.draft) { spoken.append("\(field.label): \(field.value)") }

        var y = headY + firstH
        let stemX = x + ((mark - 2) / 2).rounded()
        var threadFrame: CGRect?, quote: CGRect?
        var threadTitle = ""
        let paperTop: CGFloat
        let bodyBar: CGRect

        if !d.expanded {
            y += 6
            paperTop = y
            let flatBody = d.body.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.joined(separator: " ")
            let previewW = max(60, innerW - mark - 8)
            let (preview, _) = clamped(text(flatBody, PromptFonts.font(.subheadline, category), ChatPalette.label2), width: previewW, maxLines: 1)
            texts.append(PromptPlacedText(text: preview, frame: CGRect(x: titleX, y: y, width: previewW, height: preview.size.height)))
            bodyBar = CGRect(x: stemX, y: y + 1, width: 2, height: max(12, preview.size.height - 2))
            y += preview.size.height
            spoken.append(d.body)
        } else {
            // Expanded receipt: show extra fields (From/Via/Subject), optional conversation preview, and full sent text.
            let extraFields = DraftCards.fields(d.draft).filter { $0.label != "To" }
            if !extraFields.isEmpty {
                y += 8
                let labelFont = PromptFonts.font(.footnote, category)
                let over = category.isAccessibilityCategory
                let labelW = over ? 0 : ceil(extraFields.map { ($0.label as NSString).size(withAttributes: [.font: labelFont]).width }.max() ?? 0) + 10
                for field in extraFields {
                    let lbl = TextKitLayout(text(field.label, labelFont, ChatPalette.label2), width: nil)
                    texts.append(PromptPlacedText(text: lbl, frame: CGRect(x: titleX, y: y, width: lbl.size.width, height: lbl.size.height)))
                    if over { y += lbl.size.height }
                    let valFont = PromptFonts.font(.footnote, category, weight: field.strong ? .semibold : nil)
                    let valW = max(60, innerW - mark - 8 - labelW)
                    // People show whole and break between names (`DraftCards.shownPeople` keeps the list short).
                    let val = field.people ? TextKitLayout(text(DraftCards.shownPeople(field.value), valFont, ChatPalette.label), width: valW)
                        : clamped(text(field.value, valFont, ChatPalette.label, wrapAnywhere: !field.strong), width: valW, maxLines: 2).0
                    texts.append(PromptPlacedText(text: val, frame: CGRect(x: titleX + labelW, y: y, width: valW, height: val.size.height)))
                    y += max(val.size.height, over ? 0 : lbl.size.height) + 4
                }
            }
            if !d.draft.thread.isEmpty {
                y += 8
                threadTitle = DraftCards.threadTitle(d.draft)
                let link = TextKitLayout(text(threadTitle, PromptFonts.font(.footnote, category, weight: .medium), ChatPalette.tintText),
                                         width: max(60, innerW - mark - 8))
                let frame = CGRect(x: titleX, y: y, width: link.size.width, height: link.size.height)
                texts.append(PromptPlacedText(text: link, frame: frame))
                threadFrame = frame.insetBy(dx: -8, dy: -max(0, (44 - frame.height) / 2))
                y = frame.maxY
                quote = nil
            }
            y += 8
            paperTop = y
            let bodyW = max(60, innerW - mark - 8)
            let body = TextKitLayout(text(d.body, PromptFonts.font(.body, category), ChatPalette.label), width: bodyW)
            texts.append(PromptPlacedText(text: body, frame: CGRect(x: titleX, y: y, width: bodyW, height: body.size.height)))
            bodyBar = CGRect(x: stemX, y: y + 2, width: 2, height: max(12, body.size.height - 4))
            y += body.size.height
            spoken.append(d.body)
        }

        spoken.append(status)
        let accessibility = spoken.joined(separator: ". ")
        let paper = CGRect(x: x, y: paperTop, width: innerW, height: max(1, y - paperTop))
        let card = CGRect(x: side, y: top, width: cardW, height: ceil(y + padV - top))
        let toggleFrame = d.expanded
            ? CGRect(x: side, y: top, width: cardW, height: max(44, firstH + padV * 2))
            : card

        var draft = DraftCardLayout(showAllFrame: nil, showAllTitle: "", buttons: [], buttonFont: PromptFonts.button(category),
                                    stacked: false, paper: paper)
        draft.bodyBar = bodyBar
        draft.bodyBarTint = false
        draft.toggleFrame = toggleFrame
        draft.toggleLabel = accessibility
        draft.toggleExpanded = d.expanded
        draft.threadFrame = threadFrame
        draft.threadTitle = threadTitle
        draft.quote = quote
        var layout = PromptRowLayout(cardFrame: card, texts: texts, approval: nil, symbols: symbols, rules: [], accessibility: accessibility)
        layout.draft = draft
        return RowLayout(height: ceil(card.maxY + 4), content: .prompt(layout))
    }

    /// Clean single-surface active draft card: compact header, left accent bar (no nested box), subtle footer divider,
    /// and trailing Don't Send / Edit / Send actions.
    private static func draftWaiting(_ d: DraftCardRow, gap: CGFloat, width: CGFloat, category: UIContentSizeCategory) -> RowLayout {
        let side = cardSide
        let cardW = cardWidth(for: width), innerW = cardW - 2 * notePadH
        let top = max(0, gap) + 4, x = side + notePadH
        let title = DraftCards.heading(d.draft) + (d.edited ? " · Edited" : "")
        let fields = DraftCards.fields(d.draft)

        let headFont = PromptFonts.font(.subheadline, category, weight: .semibold, cap: 26)
        let mark = ceil(min(30, max(22, headFont.pointSize * 1.4)))
        let textX = x + mark + 8
        let headTop = top + notePadV

        var texts: [PromptPlacedText] = []
        var symbols: [PromptSymbol] = []
        var spoken = [title]
        var y: CGFloat

        // Simple single-recipient draft: combine kind and "To <recipient>" on one calm header line.
        if fields.count == 1, fields[0].label == "To", !category.isAccessibilityCategory {
            let line = NSMutableAttributedString(attributedString: text(title, headFont, ChatPalette.label))
            line.append(text("  ·  To ", PromptFonts.font(.subheadline, category, cap: 26), ChatPalette.label2))
            line.append(text(fields[0].value, PromptFonts.font(.subheadline, category, weight: .medium, cap: 26), ChatPalette.label))
            let (headLayout, _) = clamped(line, width: max(60, innerW - (textX - x)), maxLines: 2)
            let firstH = max(mark, headLayout.size.height)
            symbols.append(PromptSymbol(frame: CGRect(x: x, y: headTop + ((firstH - mark) / 2).rounded(), width: mark, height: mark),
                                        name: DraftCards.glyph(d.draft), style: .picked))
            texts.append(PromptPlacedText(text: headLayout,
                                          frame: CGRect(x: textX, y: headTop + ((firstH - headLayout.size.height) / 2).rounded(),
                                                        width: headLayout.size.width, height: headLayout.size.height)))
            spoken.append("\(fields[0].label): \(fields[0].value)")
            y = headTop + firstH + 12
        } else {
            let headLayout = TextKitLayout(text(title, headFont, ChatPalette.label), width: max(60, innerW - (textX - x)))
            let firstH = max(mark, headLayout.size.height)
            symbols.append(PromptSymbol(frame: CGRect(x: x, y: headTop + ((firstH - mark) / 2).rounded(), width: mark, height: mark),
                                        name: DraftCards.glyph(d.draft), style: .picked))
            texts.append(PromptPlacedText(text: headLayout,
                                          frame: CGRect(x: textX, y: headTop + ((firstH - headLayout.size.height) / 2).rounded(),
                                                        width: headLayout.size.width, height: headLayout.size.height)))
            y = headTop + firstH + 10
            if !fields.isEmpty {
                let labelFont = PromptFonts.font(.subheadline, category)
                let over = category.isAccessibilityCategory
                let labelW = over ? 0 : ceil(fields.map { ($0.label as NSString).size(withAttributes: [.font: labelFont]).width }.max() ?? 0) + 12
                for field in fields {
                    let label = TextKitLayout(text(field.label, labelFont, ChatPalette.label2), width: nil)
                    texts.append(PromptPlacedText(text: label, frame: CGRect(x: x, y: y, width: label.size.width, height: label.size.height)))
                    if over { y += label.size.height }
                    let valueFont = PromptFonts.font(.subheadline, category, weight: field.strong ? .semibold : nil)
                    // People show whole and break between names: a send is never approved with part of the list unseen.
                    // (`DraftCards.shownPeople` keeps the list short enough to lay out whole.)
                    let value = field.people ? TextKitLayout(text(DraftCards.shownPeople(field.value), valueFont, ChatPalette.label), width: innerW - labelW)
                        : clamped(text(field.value, valueFont, ChatPalette.label, wrapAnywhere: !field.strong), width: innerW - labelW, maxLines: 2).0
                    texts.append(PromptPlacedText(text: value, frame: CGRect(x: x + labelW, y: y, width: innerW - labelW, height: value.size.height)))
                    y += max(value.size.height, over ? 0 : label.size.height) + (over ? 6 : 4)
                    spoken.append("\(field.label): \(field.value)")
                }
                y += over ? 6 : 8
            }
        }

        // The conversation it answers: a short preview beside a bar, then a button that opens all of it in a sheet.
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
                let (words, wasCut) = clamped(text(flat.words, PromptFonts.font(.subheadline, category), ChatPalette.label2), width: textW, maxLines: left)
                left -= max(1, lineCount(words))
                whole = whole && !wasCut && flat.whole
                let who = DraftThreadText.head(message, category: category)
                blocks.insert((who.length > 0 ? TextKitLayout(who, width: textW) : nil, words, message), at: 0)
            }
            let quoteTop = y
            for (i, block) in blocks.enumerated() {
                if i > 0 { y += 8 }
                if let head = block.head {
                    texts.append(PromptPlacedText(text: head, frame: CGRect(x: x + inset, y: y, width: textW, height: head.size.height)))
                    y += head.size.height + 2
                }
                texts.append(PromptPlacedText(text: block.words, frame: CGRect(x: x + inset, y: y, width: textW, height: block.words.size.height)))
                y += block.words.size.height
                spoken.append([block.message.from, block.message.when, block.words.text.string].filter { !$0.isEmpty }.joined(separator: ", "))
            }
            quote = CGRect(x: x, y: quoteTop, width: 2.5, height: y - quoteTop)
            if !whole || blocks.count < thread.count {
                y += 8
                threadTitle = DraftCards.threadTitle(d.draft)
                let link = TextKitLayout(text(threadTitle, PromptFonts.font(.subheadline, category, weight: .medium), ChatPalette.tintText), width: innerW)
                let frame = CGRect(x: x, y: y, width: link.size.width, height: link.size.height)
                texts.append(PromptPlacedText(text: link, frame: frame))
                threadFrame = frame.insetBy(dx: -8, dy: -max(0, (44 - frame.height) / 2))
                y = frame.maxY
            }
            y += 14
        }

        // Single-surface body beside a clean tint accent bar (aligned under the header icon).
        let barX = x + ((mark - 2.5) / 2).rounded()
        let bodyInset = min(26, mark + 6)
        let wx = x + bodyInset, wordsW = max(60, innerW - bodyInset)
        let paperTop = y
        let bodyText = text(d.body, PromptFonts.font(.body, category), ChatPalette.label)
        let (body, cut) = clamped(bodyText, width: wordsW, maxLines: d.expanded ? 0 : PromptRows.draftClampLines)
        texts.append(PromptPlacedText(text: body, frame: CGRect(x: wx, y: y, width: wordsW, height: body.size.height)))
        let bodyBar = CGRect(x: barX, y: y + 2, width: 2.5, height: max(14, body.size.height - 4))
        y += body.size.height
        spoken.append(d.body)
        var showAllFrame: CGRect?
        let showAllTitle = d.expanded ? "Show Less" : "Show All"
        if cut || d.expanded && lineCount(body) > PromptRows.draftClampLines {
            let more = TextKitLayout(text(showAllTitle, PromptFonts.font(.footnote, category), ChatPalette.tintText), width: nil)
            let frame = CGRect(x: wx, y: y + 6, width: more.size.width, height: more.size.height)
            texts.append(PromptPlacedText(text: more, frame: frame))
            showAllFrame = frame.insetBy(dx: -8, dy: -(44 - frame.height) / 2)
            y = frame.maxY
        }
        let paper = CGRect(x: x, y: paperTop, width: innerW, height: max(1, y - paperTop))

        // Subtle divider above the action row.
        y += 13
        let footerDivider = CGRect(x: x, y: y, width: innerW, height: 0)
        y += 11

        // Actions: one trailing row (Don't Send, Edit, Send), or full width stacked with Send first.
        let font = PromptFonts.button(category)
        let order: [DraftButton] = [.skip, .edit, .send]
        let h = max(44, ceil(font.lineHeight) + 16)
        let widths = order.map { ceil((draftButtonTitle($0) as NSString).size(withAttributes: [.font: font]).width) + 32 }
        let rowW = widths.reduce(0, +) + CGFloat(order.count - 1) * 8
        let stacked = category.isAccessibilityCategory || rowW > innerW
        var placed: [(DraftButton, CGRect)] = []
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

        let card = CGRect(x: side, y: top, width: cardW, height: ceil(y + notePadV - top))
        var layout = PromptRowLayout(cardFrame: card, texts: texts, approval: nil, symbols: symbols, rules: [],
                                     accessibility: spoken.joined(separator: ". "))
        var draft = DraftCardLayout(showAllFrame: showAllFrame, showAllTitle: showAllTitle, buttons: placed, buttonFont: font, stacked: stacked,
                                    paper: paper)
        draft.bodyBar = bodyBar
        draft.bodyBarTint = true
        draft.footerDivider = footerDivider
        draft.threadFrame = threadFrame
        draft.threadTitle = threadTitle
        draft.quote = quote
        layout.draft = draft
        return RowLayout(height: ceil(card.maxY + 4), content: .prompt(layout))
    }
}
