import UIKit
import Markdown

// Markdown → attributed text blocks for chat bubbles (spec 03 §9.5, the M1 subset on swift-markdown).
// Pure and thread-safe: call it from any thread. Colours are dynamic, so one render serves light and dark.

extension NSAttributedString.Key {
    /// A tappable link inside chat text (URL). We don't use `.link`: string drawing would restyle it.
    nonisolated static let chatLink = NSAttributedString.Key("HQChatLink")
    /// [morepages] A Markdown link's destination as written, on the link's text (3x-morepages §3).
    nonisolated static let markdownDestination = NSAttributedString.Key("HQMarkdownDestination")
    /// Inline code's text as written (String): one tap copies it, as Telegram copies its monospace spans.
    nonisolated static let chatCopy = NSAttributedString.Key("HQChatCopy")
    /// Inline code: `ChatLayoutManager` draws its `.backgroundColor` as a rounded box around the glyphs.
    nonisolated static let inlineCodeBox = NSAttributedString.Key("HQInlineCodeBox")
    /// A code block flattened into a page's text (a Markdown file's Preview): `ChatLayoutManager` draws its
    /// `.backgroundColor` as one padded box across the column.
    nonisolated static let codeBlockBox = NSAttributedString.Key("HQCodeBlockBox")
    /// A diff's added or removed line (`WorkspaceTextPage`): `ChatLayoutManager` washes the whole row, edge to edge.
    nonisolated static let lineWash = NSAttributedString.Key("HQLineWash")
    /// [transcript] F17: a formula's drawn text (readable or, when it can't be drawn, its TeX source) — never treated
    /// as a bare file path by `linkBarePaths` (an inline fraction can read "(a+b)/c").
    nonisolated static let mathFormula = NSAttributedString.Key("HQMathFormula")
    /// [transcript] F17: a big operator's limit (`MathStyle`) carries its own baseline shift *on top of* the
    /// paragraph's line-centring offset (CGFloat); `appendParagraph` adds it in after setting the uniform offset, since
    /// that call would otherwise overwrite a per-run `.baselineOffset` across the whole paragraph.
    nonisolated static let mathLimitOffset = NSAttributedString.Key("HQMathLimitOffset")
}

/// One block of a rendered message, stacked vertically inside a bubble.
nonisolated enum MarkdownBlock: @unchecked Sendable {
    /// Prose: paragraphs, headings and lists, merged into one attributed string (paragraph spacing inside).
    case text(NSAttributedString)
    /// A block quote (leading bar) or, when `alert` is set, a GFM alert callout.
    case quote(NSAttributedString, alert: MarkdownAlert?)
    /// A fenced or indented code block: plain monospace, language label (nil = none), raw code for Copy.
    case code(label: String?, code: String, text: NSAttributedString, lineCount: Int)
    /// A GFM table: a grid that scrolls sideways inside the bubble (spec 03 §9.5).
    case table(MarkdownTable)
    /// `---`: quiet vertical space, no rule.
    case spacer(CGFloat)
    /// [attachments] A paragraph of media only (`MEDIA:` links, images, file-path links): photos and file rows
    /// (docs/spec/1x-attachments.md §7.5).
    case media([MediaRef])
    /// [transcript] A web address alone on its paragraph of a reply: a chip under it with the site's icon, the page's
    /// title and the host (docs/spec/3x-transcript.md §3.7).
    case linkChip(URL)
    /// An HTML page alone on its paragraph of a settled reply (`::preview{file="…"}`, a `MEDIA:` page): a card with a
    /// picture of the page that opens it live (`PageCardView`).
    case pageCard(MediaRef)

    var isProse: Bool { if case .text = self { return true } else { return false } }
}

/// A GFM table's cells (13 pt text; the header semibold in the secondary colour), column alignments, and copy text.
nonisolated struct MarkdownTable: @unchecked Sendable {
    var header: [NSAttributedString]
    var rows: [[NSAttributedString]]
    var alignments: [NSTextAlignment]
    /// Tab-separated rows, header first (Copy).
    var plain: String
    /// The same as attributed lines: a table inside a quote reads as prose.
    var flat: NSAttributedString
    /// [transcript] Columns of numbers only ("20.7%", "$5"): with no alignment of their own they read right-aligned.
    var numeric: [Bool] = []
    /// [transcript] The words above the table that name it ("Rep by rep (minimum 40 orders):"): the Table page's
    /// title. Nil when the prose before it doesn't introduce it.
    var caption: String? = nil

    var columnCount: Int { max(header.count, rows.map(\.count).max() ?? 0) }

    /// How column `c` lines up: its own Markdown alignment, else right for a column of numbers.
    func alignment(_ c: Int) -> NSTextAlignment {
        let own = c < alignments.count ? alignments[c] : .natural
        if own == .natural, c < numeric.count, numeric[c] { return .right }
        return own
    }

    /// Every row's cells as plain words, header first.
    var words: [[String]] { ([header] + rows).map { $0.map(\.string) } }
}

nonisolated struct MarkdownAlert: Sendable, Hashable {
    let title: String
    let symbol: String
}

nonisolated struct RenderedMarkdown: @unchecked Sendable {
    var blocks: [MarkdownBlock]
    /// Plain text for Copy.
    var plainText: String
    /// A code card's or quote's leading indent, by block index: one written inside a list item sits under the item's
    /// text, not at the bubble's edge.
    var indents: [Int: CGFloat] = [:]
    /// The last block is prose, so the bubble time can share its last line (spec 06 §2.3).
    var endsWithProse: Bool { blocks.last?.isProse ?? true }
}

/// Colours that differ between your bubble and a bot's.
nonisolated struct MarkdownTheme: @unchecked Sendable, Hashable {
    let text: UIColor
    let secondary: UIColor
    let marker: UIColor
    let link: UIColor
    let underlineLinks: Bool
    let inlineCodeFill: UIColor
    let variant: Int   // part of cache keys

    // A list's bullets and numbers in the secondary ink: the tertiary one was about 2:1 on a white page and less on a
    // bot's grey bubble (2026-10-29 screenshot review).
    static let bot = MarkdownTheme(text: ChatPalette.label, secondary: ChatPalette.label2, marker: ChatPalette.label2,
                                   link: ChatPalette.tintText, underlineLinks: false,
                                   inlineCodeFill: ChatPalette.inlineCodeFill, variant: 0)
    // Inline code's box in your bubble is your text's own ink at 18 % (white over the tint; dark on a skin whose own
    // bubble is light with dark words, where a fixed white box couldn't be seen).
    static let me = MarkdownTheme(text: ChatPalette.meText, secondary: ChatPalette.meTime, marker: ChatPalette.meTime,
                                  link: ChatPalette.meText, underlineLinks: true,
                                  inlineCodeFill: UIColor { @Sendable traits in
                                      ChatPalette.meText.resolvedColor(with: traits).withAlphaComponent(0.18)
                                  }, variant: 1)

    static func == (a: MarkdownTheme, b: MarkdownTheme) -> Bool { a.variant == b.variant }
    func hash(into hasher: inout Hasher) { hasher.combine(variant) }
}

nonisolated enum MarkdownRenderer {
    /// Text over this many characters is drawn as plain text (spec 03 §9.3).
    static let plainTextLimit = 200_000

    /// Render markdown for a bubble. Text past the size or complexity limits is drawn as plain text (spec 03 §9.3).
    /// `highlight`: colour code blocks by token (spec 06 §2.6) — only once the message has stopped streaming.
    /// `filePaths`: a path in inline code is a link that opens the file (`FileLinks`): a bot's reply in the chat.
    /// `streaming`: the reply is still arriving (an unclosed thinking tag on its own line hides what follows it).
    static func render(_ markdown: String, style: ChatStyle, theme: MarkdownTheme = .bot, highlight: Bool = false,
                       linkChips: Bool = false, filePaths: Bool = false, streaming: Bool = false) -> RenderedMarkdown {
        // Copy, Share and VoiceOver start from `plainText`: the reply as written, less its hidden thinking.
        let shown = ReasoningTags.strip(markdown, streaming: streaming)
        if markdown.utf16.count > plainTextLimit {
            return RenderedMarkdown(blocks: [.text(plain(shown, style: style, theme: theme))], plainText: shown)
        }
        // [transcript] §3.5 / F17: formulas come out before Markdown can eat their `_`/`\`.
        let math = MathText.extract(MarkdownPreprocess.run(markdown, streaming: streaming))
        let source = math.text
        let formulas = math.formulas
        switch MarkdownComplexity.verdict(source) {
        case .tooComplex:
            return RenderedMarkdown(blocks: [.text(plain(shown, style: style, theme: theme))], plainText: shown)
        case .deep:
            // Within the limits but deeply nested: parse where the stack is big (the recursion is per nesting level).
            let rendered = BigStackRunner.shared.run {
                UncheckedSendable(parse(source, style: style, theme: theme, highlight: highlight, linkChips: linkChips,
                                        filePaths: filePaths, formulas: formulas, plainText: shown))
            }
            return rendered.value
        case .simple:
            return parse(source, style: style, theme: theme, highlight: highlight, linkChips: linkChips,
                         filePaths: filePaths, formulas: formulas, plainText: shown)
        }
    }

    /// Your own message: inline markdown and code fences only (`UserMarkdown`); plain text when there is none.
    static func renderUser(_ text: String, style: ChatStyle) -> RenderedMarkdown {
        guard text.utf16.count <= plainTextLimit, UserMarkdown.hasMarkup(text) else {
            return RenderedMarkdown(blocks: [.text(plain(text, style: style, theme: .me))], plainText: text)
        }
        let source = MarkdownPreprocess.escapeURLMarkup(UserMarkdown.escapeBlocks(text))
        guard MarkdownComplexity.verdict(source) == .simple else {
            return RenderedMarkdown(blocks: [.text(plain(text, style: style, theme: .me))], plainText: text)
        }
        return parse(source, style: style, theme: .me, highlight: false, plainText: text)
    }

    /// [transcript] The paragraph is one bare https address and nothing else (an address the author gave words to,
    /// A bot's HTML page on its computer (a page card, not a file row).
    nonisolated static func isPage(_ ref: MediaRef) -> Bool {
        ref.attachment.gatewayPath.map { HTMLPageSheet.opens(name: $0) } ?? false
    }

    /// `[text](url)`, is not bare: its paragraph's plain text is the words).
    static func loneWebAddress(_ paragraph: String) -> URL? {
        let text = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("https://"), text.count <= 2048, !text.contains(where: \.isWhitespace),
              let url = URL(string: text), let host = url.host, host.contains(".") else { return nil }
        return url
    }

    private static func parse(_ source: String, style: ChatStyle, theme: MarkdownTheme, highlight: Bool,
                              linkChips: Bool = false, filePaths: Bool = false,
                              formulas: [MathText.Span.Taken] = [], plainText: String) -> RenderedMarkdown {
        let document = Document(parsing: source, options: [.disableSmartOpts, .disableSourcePosOpts])
        var builder = BlockBuilder(style: style, theme: theme)
        builder.highlight = highlight
        builder.linkChips = linkChips
        builder.filePaths = filePaths
        builder.formulas = formulas
        builder.blocks(of: document)
        builder.flush()
        return RenderedMarkdown(blocks: builder.out, plainText: plainText, indents: builder.indents)
    }

    /// Plain text (your own messages): single newlines kept, no markdown (spec 03 §9.5, user bubbles).
    static func plain(_ text: String, style: ChatStyle, theme: MarkdownTheme) -> NSAttributedString {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let para = paragraphStyle(lineHeight: style.bodyLineHeight, font: style.body, spacingBefore: 0)
        return NSAttributedString(string: normalized.replacingOccurrences(of: "\n", with: "\u{2028}"), attributes: [
            .font: style.body, .foregroundColor: theme.text, .paragraphStyle: para,
            .baselineOffset: baselineOffset(lineHeight: style.bodyLineHeight, font: style.body),
        ])
    }

    // MARK: Helpers shared with the layout code

    /// A fixed line pitch of `lineHeight` (CSS `line-height`). TextKit 1 adds the font's own leading under every line
    /// after the min/max clamp (SF at 17 pt: 23 became 24.7 pt, 7 % looser than the web; verification round 2), so the
    /// clamp is the pitch less that leading.
    static func paragraphStyle(lineHeight: CGFloat, font: UIFont, spacingBefore: CGFloat, headIndent: CGFloat = 0,
                               firstLineHeadIndent: CGFloat = 0, tabStop: CGFloat? = nil,
                               lineBreak: NSLineBreakMode = .byWordWrapping) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        let line = max(font.ascender - font.descender, lineHeight - max(0, font.leading))
        p.minimumLineHeight = line
        p.maximumLineHeight = line
        p.paragraphSpacingBefore = spacingBefore
        p.headIndent = headIndent
        p.firstLineHeadIndent = firstLineHeadIndent
        p.lineBreakMode = lineBreak
        if let tabStop { p.tabStops = [NSTextTab(textAlignment: .left, location: tabStop)]; p.defaultTabInterval = tabStop }
        return p
    }

    /// Centres the glyphs in a fixed line pitch (CSS half-leading). Where TextKit leaves the glyphs inside the clamped
    /// line depends on the font's metrics, so it is measured once per font and pitch: one line laid out with no offset.
    /// (The old fixed formula sat body text on the line's top with all the room below it.)
    static func baselineOffset(lineHeight: CGFloat, font: UIFont) -> CGFloat {
        // The metrics are in the key, not only the name and size: the Desktop Look's body is the same SF Pro at the same
        // size with no leading, and the iOS look's offset (leading 2.1 pt) reused there drew every reply 2 pt low after
        // a live switch into it (Mac polish #81).
        let key = "\(font.fontName)|\(font.pointSize)|\(font.leading)|\(font.ascender)|\(font.descender)|\(lineHeight)"
        offsetLock.lock()
        if let known = offsets[key] { offsetLock.unlock(); return known }
        offsetLock.unlock()
        let para = paragraphStyle(lineHeight: lineHeight, font: font, spacingBefore: 0)
        let storage = NSTextStorage(string: "Hg", attributes: [.font: font, .paragraphStyle: para])
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 1000, height: 1000))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        let top = manager.location(forGlyphAt: 0).y - font.ascender          // where TextKit leaves the glyphs
        let wanted = max(0, lineHeight - (font.ascender - font.descender)) / 2
        // TextKit honours a raised baseline but not a lowered one in a clamped line: at most 0.4 pt off centre.
        let offset = max(0, top - wanted).rounded(toPlaces: 2)
        offsetLock.lock()
        if offsets.count > 512 { offsets.removeAll() }
        offsets[key] = offset
        offsetLock.unlock()
        return offset
    }

    private static let offsetLock = NSLock()
    nonisolated(unsafe) private static var offsets: [String: CGFloat] = [:]

    /// `codeLanguageLabel` (spec 06 §2.6): `CodeLanguage.label`, which VoiceOver's code summary shares.
    static func codeLanguageLabel(_ raw: String?) -> String? { CodeLanguage.label(raw) }

    /// Bare URLs, by the web's own rule (spec 03 §9.5): `*` never joins, trailing `.,;:!?` peel off, and so does a
    /// closing `)` or `]` nothing in the address opened (`bareURLEnd`). Full-width punctuation (`。`, `，`, `）`, `」`…)
    /// ends an address too: a Chinese or Japanese sentence runs straight on from one with no space.
    static let bareURL: NSRegularExpression = {
        let stops = "。，、；：！？（）「」『』【】《》〈〉"
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: "https?://[^\\s<>\"'`*\(stops)]+[^\\s<>\"'`*.,;:!?\(stops)]",
                                        options: [.caseInsensitive])
    }()

    /// How much of a bare-URL match is the address (UTF-16 units): the web's `bareUrlEnd`. A trailing `)` or `]` stays
    /// only when the address opened it (`…/wiki/Foo_(bar)`, `http://[::1]/`), so "(see https://site.com/page)" links
    /// ".../page"; punctuation that peel exposes goes too ("(https://x.)").
    static func bareURLEnd(_ url: NSString) -> Int {
        var end = url.length
        while end > 0 {
            let last = url.character(at: end - 1)
            let stray = (last == 0x29 || last == 0x5D) && !pairedCloser(url, at: end - 1)
            guard stray || ".,;:!?".utf16.contains(last) else { break }
            end -= 1
        }
        return end
    }

    private static func pairedCloser(_ url: NSString, at index: Int) -> Bool {
        let close = url.character(at: index)
        let open: unichar = close == 0x29 ? 0x28 : 0x5B
        var depth = 0
        for i in 0..<index {
            let c = url.character(at: i)
            if c == open { depth += 1 } else if c == close && depth > 0 { depth -= 1 }
        }
        return depth > 0
    }
}

nonisolated extension CGFloat {
    func rounded(toPlaces places: Int) -> CGFloat {
        let m = pow(10, CGFloat(places))
        return (self * m).rounded() / m
    }
}

// MARK: - Block walker

nonisolated private struct InlineContext {
    var bold = false
    var italic = false
    var strike = false
    var link: URL?
    /// [morepages] The link's destination as written (a note's relative link has no URL): `.markdownDestination`.
    var dest: String?
    var font: UIFont?          // overrides body (headings)
    var color: UIColor?
}

nonisolated private struct BlockBuilder {
    let style: ChatStyle
    let theme: MarkdownTheme
    var highlight = false
    /// [transcript] The chat's replies: a bare web address alone on its paragraph gets a chip (§3.7).
    var linkChips = false
    /// A path in inline code opens the file (`FileLinks`).
    var filePaths = false
    /// [transcript] F17: the reply's formulas, by the index their tokens carry (`MathText.extract`).
    var formulas: [MathText.Span.Taken] = []
    var out: [MarkdownBlock] = []
    /// A code card's or quote's indent inside a list item, by its index in `out`.
    var indents: [Int: CGFloat] = [:]
    /// Prose accumulated since the last non-prose block.
    var prose = NSMutableAttributedString()

    init(style: ChatStyle, theme: MarkdownTheme) {
        self.style = style
        self.theme = theme
    }

    mutating func flush() {
        if prose.length > 0 {
            out.append(.text(prose))
            prose = NSMutableAttributedString()
        }
    }

    /// Paragraph gap before the next prose paragraph: none at the start of a block.
    private func gapBefore(_ gap: CGFloat) -> CGFloat { prose.length == 0 ? 0 : gap }

    mutating func blocks(of container: Markup) {
        for child in container.children { block(child) }
    }

    mutating func block(_ node: Markup) {
        switch node {
        case let p as Paragraph:
            if let refs = MarkdownMedia.mediaOnly(p) {                       // [attachments] spec §7.5
                flush()
                // A settled reply's pages: each a page card (the desktop draws them live in the reply).
                if linkChips, refs.allSatisfy(MarkdownRenderer.isPage) {
                    out.append(contentsOf: refs.map(MarkdownBlock.pageCard))
                    return
                }
                // Pictures one paragraph after another, nothing between, are one set (a stack you swipe through).
                if case .media(let before)? = out.last {
                    out[out.count - 1] = .media(before + refs)
                } else {
                    out.append(.media(refs))
                }
                return
            }
            if let index = MathText.blockToken(p.plainText), index < formulas.count {   // [transcript] F17
                appendDisplayFormula(formulas[index])
                return
            }
            let text = inlineText(p.children, InlineContext())
            if text.length == 0 { return }
            // item 14: a paragraph that is only the bare link gets a card and nothing else — the line of blue text
            // above it repeated the same address. A link inside a sentence keeps its text (the chip is skipped).
            if linkChips, let url = MarkdownRenderer.loneWebAddress(p.plainText) {   // [transcript] §3.7
                flush()
                out.append(.linkChip(url))
                return
            }
            appendParagraph(text, font: style.body, lineHeight: style.bodyLineHeight, before: gapBefore(style.paragraphGap))
        case let h as Heading:
            let font = style.headings[min(max(h.level, 1), 3) - 1]
            var ctx = InlineContext()
            ctx.font = font
            ctx.bold = true
            let text = inlineText(h.children, ctx)
            if text.length == 0 { return }
            let line = (font.pointSize * 1.3).rounded(.up)
            appendParagraph(text, font: font, lineHeight: line, before: gapBefore((font.pointSize * 1.1).rounded()),
                            after: (font.pointSize * 0.35).rounded())
        case let list as UnorderedList:
            appendList(list, ordered: false, start: 1, depth: 0)
        case let list as OrderedList:
            appendList(list, ordered: true, start: Int(list.startIndex), depth: 0)
        case let quote as BlockQuote:
            flush()
            appendQuote(quote)
        case let code as CodeBlock:
            flush()
            appendCode(code)
        case let table as Markdown.Table:
            flush()
            appendTable(table)
        case is ThematicBreak:
            flush()
            out.append(.spacer(ChatMetrics.ruleSpace))
        case let html as HTMLBlock:
            let raw = html.rawHTML.trimmingCharacters(in: .newlines)
            if raw.isEmpty { return }
            let text = styled(raw.replacingOccurrences(of: #"<br\s*/?>"#, with: "\u{2028}", options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: "\n", with: "\u{2028}"), InlineContext())
            appendParagraph(text, font: style.body, lineHeight: style.bodyLineHeight, before: gapBefore(style.paragraphGap))
        default:
            // Unknown block (directives etc.): render its children as blocks, else its text.
            if node.childCount > 0 { blocks(of: node) }
        }
    }

    private mutating func appendParagraph(_ text: NSAttributedString, font: UIFont, lineHeight: CGFloat, before: CGFloat,
                                          after: CGFloat = 0, headIndent: CGFloat = 0, firstIndent: CGFloat = 0,
                                          tabStop: CGFloat? = nil, centred: Bool = false) {
        let plain = MarkdownRenderer.paragraphStyle(lineHeight: lineHeight, font: font, spacingBefore: before, headIndent: headIndent,
                                                    firstLineHeadIndent: firstIndent, tabStop: tabStop)
        var para = plain
        if centred, let centre = plain.mutableCopy() as? NSMutableParagraphStyle {   // [transcript] F17: a display formula
            centre.alignment = .center
            para = centre
        }
        let m = NSMutableAttributedString(attributedString: text)
        let full = NSRange(location: 0, length: m.length)
        // A typeset formula taller than the words' line (a fraction in a sentence): its line grows to hold it. The
        // fixed pitch would cut its top off and run it into the line above (2026-11-09 pictures); the other lines
        // keep the pitch through the minimum.
        var tall = false
        m.enumerateAttribute(.attachment, in: full, options: []) { value, _, stop in
            if let set = value as? MathAttachment, set.bounds.height > para.maximumLineHeight - 2 { tall = true; stop.pointee = true }
        }
        if tall, let loose = para.mutableCopy() as? NSMutableParagraphStyle {
            loose.maximumLineHeight = 0
            para = loose
        }
        m.addAttribute(.paragraphStyle, value: para, range: full)
        let lineOffset = MarkdownRenderer.baselineOffset(lineHeight: lineHeight, font: font)
        m.addAttribute(.baselineOffset, value: lineOffset, range: full)
        // [transcript] F17: a big operator's limit (MathStyle) keeps its own extra shift on top of the line's offset —
        // the blanket assignment above would otherwise overwrite it.
        m.enumerateAttribute(.mathLimitOffset, in: full, options: []) { value, range, _ in
            guard let delta = value as? CGFloat else { return }
            m.addAttribute(.baselineOffset, value: lineOffset + delta, range: range)
        }
        if after > 0 {
            // Space below a heading: carried by the next paragraph's spacingBefore would be lost at a block end, so a
            // heading adds it as paragraphSpacing (ignored after the last line).
            let p2 = (para.mutableCopy() as! NSMutableParagraphStyle)
            p2.paragraphSpacing = after
            m.addAttribute(.paragraphStyle, value: p2, range: full)
        }
        if prose.length > 0 {
            // The separator ends the previous paragraph, so it carries that paragraph's attributes.
            let previous = prose.attributes(at: prose.length - 1, effectiveRange: nil)
                .filter { $0.key == .font || $0.key == .paragraphStyle || $0.key == .baselineOffset }
            prose.append(NSAttributedString(string: "\n", attributes: previous))
        }
        prose.append(m)
    }

    // MARK: Lists

    /// A list at `leading` (its markers' edge): each item's text hangs at `leading` plus the indent, which is the
    /// style's (1.625 em) or, when a marker is wider than that ("100." at the default size, any number at the largest
    /// text sizes), the widest marker and a gap, so every first line lines up with the lines that wrap under it.
    private mutating func appendList(_ list: ListItemContainer, ordered: Bool, start: Int, depth: Int, leading: CGFloat = 0) {
        let items = list.children.compactMap { $0 as? ListItem }
        let markers: [String] = items.enumerated().map { offset, item in
            if let box = item.checkbox { return box == .checked ? "☑︎" : "☐" }
            if ordered { return "\(start + offset)." }
            return ["•", "◦", "▪︎"][min(depth, 2)]
        }
        let widest = Set(markers).map { ceil(($0 as NSString).size(withAttributes: [.font: style.body]).width) }.max() ?? 0
        let indent = max(style.listIndent, widest + (style.body.pointSize * 0.35).rounded())
        let head = leading + indent
        var first = true
        for (item, marker) in zip(items, markers) {
            var firstPara = true
            for child in item.children {
                switch child {
                case let p as Paragraph:
                    let content = inlineText(p.children, InlineContext())
                    let gap: CGFloat = (first && firstPara) ? gapBefore(depth == 0 ? style.paragraphGap : 4) : 4
                    if firstPara {
                        let line = NSMutableAttributedString(string: marker + "\t", attributes: [
                            .font: style.body, .foregroundColor: theme.marker,
                        ])
                        line.append(content)
                        appendParagraph(line, font: style.body, lineHeight: style.bodyLineHeight, before: gap,
                                        headIndent: head, firstIndent: leading, tabStop: head)
                    } else {
                        appendParagraph(content, font: style.body, lineHeight: style.bodyLineHeight, before: gap,
                                        headIndent: head, firstIndent: head)
                    }
                    firstPara = false
                case let sub as UnorderedList:
                    if firstPara { appendEmptyMarker(marker, leading: leading, head: head); firstPara = false }
                    appendList(sub, ordered: false, start: 1, depth: depth + 1, leading: head)
                case let sub as OrderedList:
                    if firstPara { appendEmptyMarker(marker, leading: leading, head: head); firstPara = false }
                    appendList(sub, ordered: true, start: Int(sub.startIndex), depth: depth + 1, leading: head)
                default:
                    // A code block or quote inside a list item: a block of its own, set in under the item's text.
                    if firstPara { appendEmptyMarker(marker, leading: leading, head: head) }
                    let at = out.count
                    block(child)
                    for index in at..<out.count {
                        switch out[index] {
                        case .code, .quote: indents[index] = head
                        default: break
                        }
                    }
                    firstPara = false
                }
            }
            if firstPara { appendEmptyMarker(marker, leading: leading, head: head) }
            first = false
        }
    }

    private mutating func appendEmptyMarker(_ marker: String, leading: CGFloat, head: CGFloat) {
        let line = NSAttributedString(string: marker, attributes: [.font: style.body, .foregroundColor: theme.marker])
        appendParagraph(line, font: style.body, lineHeight: style.bodyLineHeight, before: gapBefore(4),
                        headIndent: head, firstIndent: leading)
    }

    // MARK: Quotes, code, tables

    private mutating func appendQuote(_ quote: BlockQuote) {
        var inner = BlockBuilder(style: style, theme: theme)
        inner.filePaths = filePaths
        inner.formulas = formulas
        var alert: MarkdownAlert?
        var children = Array(quote.children)
        // GFM alert: "[!NOTE]" (+ optional spaces and one newline) at the start of the first paragraph.
        if let p = children.first as? Paragraph, let t = p.children.first(where: { _ in true }) as? Markdown.Text,
           let match = t.string.range(of: #"^\[!(note|tip|important|warning|caution)\][ \t]*$"#,
                                      options: [.regularExpression, .caseInsensitive]) {
            let kind = t.string[match].dropFirst(2).prefix { $0 != "]" }.lowercased()
            let titles: [String: (String, String)] = [
                "note": ("Note", "info.circle"), "tip": ("Tip", "lightbulb"), "important": ("Important", "exclamationmark.bubble"),
                "warning": ("Warning", "exclamationmark.triangle"), "caution": ("Caution", "exclamationmark.octagon"),
            ]
            if let (title, symbol) = titles[kind] {
                alert = MarkdownAlert(title: title, symbol: symbol)
                // Drop the marker text node and the soft break that follows it.
                var rest = Array(p.children.dropFirst())
                if rest.first is SoftBreak || rest.first is LineBreak { rest.removeFirst() }
                let text = inner.inlineText(rest, InlineContext())
                if text.length > 0 {
                    inner.appendParagraph(text, font: style.body, lineHeight: style.bodyLineHeight, before: 0)
                }
                children.removeFirst()
            }
        }
        for child in children { inner.block(child) }
        inner.flush()
        // Flatten the quote's blocks into one attributed string (nested code in quotes reads as monospace prose).
        let joined = NSMutableAttributedString()
        for b in inner.out {
            let piece: NSAttributedString
            switch b {
            case .text(let t), .quote(let t, _): piece = t
            case .table(let table): piece = table.flat
            case .code(_, _, let t, _): piece = t
            case .spacer, .linkChip, .pageCard: continue
            case .media(let refs): piece = styled(refs.map(\.label).joined(separator: ", "), InlineContext())   // [attachments]
            }
            if joined.length > 0 { joined.append(NSAttributedString(string: "\n")) }
            joined.append(piece)
        }
        if alert == nil {
            // Quotes read secondary and italic.
            joined.enumerateAttribute(.font, in: NSRange(location: 0, length: joined.length)) { value, range, _ in
                guard let f = value as? UIFont, !f.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) else { return }
                if let d = f.fontDescriptor.withSymbolicTraits(f.fontDescriptor.symbolicTraits.union(.traitItalic)) {
                    joined.addAttribute(.font, value: UIFont(descriptor: d, size: f.pointSize), range: range)
                }
            }
            joined.enumerateAttribute(.chatLink, in: NSRange(location: 0, length: joined.length)) { value, range, _ in
                if value == nil { joined.addAttribute(.foregroundColor, value: theme.secondary, range: range) }
            }
        }
        if joined.length == 0 && alert == nil { return }
        out.append(.quote(joined, alert: alert))
    }

    private mutating func appendCode(_ code: CodeBlock) {
        var body = code.code
        if body.hasSuffix("\n") { body.removeLast() }
        body = body.replacingOccurrences(of: "\t", with: "  ")
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }   // empty fences are dropped
        let para = MarkdownRenderer.paragraphStyle(lineHeight: style.codeLineHeight, font: style.code, spacingBefore: 0,
                                                   lineBreak: ChatRenderOptions.codeBlocksWrap ? .byWordWrapping : .byClipping)
        let text = NSMutableAttributedString(string: body, attributes: [
            .font: style.code, .foregroundColor: ChatPalette.codeText, .paragraphStyle: para,
            .baselineOffset: MarkdownRenderer.baselineOffset(lineHeight: style.codeLineHeight, font: style.code),
        ])
        // Token colours only (same fonts, so the same geometry as the plain card the streaming message showed).
        if highlight, let tokens = SyntaxHighlighter.tokens(body, language: code.language) {
            SyntaxHighlighter.apply(tokens, to: text)
        }
        let lines = body.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        out.append(.code(label: MarkdownRenderer.codeLanguageLabel(code.language), code: body, text: text, lineCount: lines))
    }

    // MARK: Formulas ([transcript] F17, spec §3.5)

    /// A display formula on its own lines: centred in the bubble, 8 pt more above and below; outside the readable
    /// subset, its TeX source as a code card — the same card every other code block uses, so wide source (like
    /// `\begin{aligned}…\end{aligned}`) scrolls sideways instead of clipping (§12.3; `appendCodeText`).
    private mutating func appendDisplayFormula(_ formula: MathText.Span.Taken) {
        // Typeset when it can be (`MathTypeset`): its own centred paragraph, a line as tall as the formula.
        if let set = MathTypeset.attachment(formula.source, block: true, base: style.body, maxWidth: MathTypeset.blockWidth) {
            appendTypesetFormula(set, copy: formula.source)
            return
        }
        guard let readable = MathText.readable(formula.source, block: true) else {
            flush()
            appendCodeText(formula.source)
            return
        }
        let text = MathStyle.attributed(readable, base: style.body, color: theme.text, copy: formula.source)
        appendParagraph(text, font: style.body, lineHeight: style.bodyLineHeight,
                        before: prose.length == 0 ? 0 : style.paragraphGap + MathStyle.blockGap, after: MathStyle.blockGap, centred: true)
    }

    /// A typeset display formula as its own paragraph. Its line is the formula's height (the words' fixed pitch
    /// would cut a matrix), and the formula stands on the line's floor: TextKit puts a clamped line's baseline the
    /// font's descent above its floor, so the attachment hangs that far below the baseline.
    private mutating func appendTypesetFormula(_ set: MathAttachment, copy: String) {
        let font = style.body
        let height = set.bounds.height
        set.bounds.origin.y = font.descender
        let para = NSMutableParagraphStyle()
        para.minimumLineHeight = height
        para.maximumLineHeight = height
        para.alignment = .center
        para.paragraphSpacingBefore = prose.length == 0 ? 0 : style.paragraphGap + MathStyle.blockGap
        para.paragraphSpacing = MathStyle.blockGap
        let m = NSMutableAttributedString(attributedString: MathTypeset.attributed(set, base: font, color: theme.text, copy: copy))
        m.addAttributes([.paragraphStyle: para, .mathFormula: true], range: NSRange(location: 0, length: m.length))
        if prose.length > 0 {
            let previous = prose.attributes(at: prose.length - 1, effectiveRange: nil)
                .filter { $0.key == .font || $0.key == .paragraphStyle || $0.key == .baselineOffset }
            prose.append(NSAttributedString(string: "\n", attributes: previous))
        }
        prose.append(m)
    }

    /// A formula inside a sentence: typeset, or readable text in the serif, or its source in the code font.
    fileprivate func inlineFormula(_ formula: MathText.Span.Taken, _ ctx: InlineContext) -> NSAttributedString {
        var attrs = attributes(ctx)
        let base = attrs[.font] as? UIFont ?? style.body
        let color = attrs[.foregroundColor] as? UIColor ?? theme.text
        if MathTypeset.needsTypesetting(formula.source) || MathText.readable(formula.source, block: false) == nil,
           let set = MathTypeset.attachment(formula.source, block: false, base: base,
                                            maxHeight: (base.lineHeight * MathTypeset.inlineHeightRatio).rounded(),
                                            maxWidth: MathTypeset.blockWidth) {
            let out = NSMutableAttributedString(attributedString: MathTypeset.attributed(set, base: base, color: color,
                                                                                      copy: ctx.link == nil ? formula.source : nil))
            let full = NSRange(location: 0, length: out.length)
            out.addAttribute(.mathFormula, value: true, range: full)
            if let link = ctx.link { out.addAttribute(.chatLink, value: link, range: full) }
            return out
        }
        guard let readable = MathText.readable(formula.source, block: false) else {
            attrs[.font] = style.inlineCode.withSize(base.pointSize * style.inlineCode.pointSize / max(1, style.body.pointSize))
            attrs[.mathFormula] = true
            if ctx.link == nil { attrs[.chatCopy] = formula.source }
            return NSAttributedString(string: formula.written, attributes: attrs)
        }
        // Every space inside an inline formula is non-breaking: `readable`'s own spaces ("i = 1", "a = b") are
        // ordinary line-break points to TextKit like any other word gap, so a long inline formula could break across
        // lines in its own middle (screenshot review of the n20 revisit, 2026-10-31: "∑…i" ended one line and
        // "= n(n+1)/2." began the next). Either the whole formula fits on the line, or the whole formula moves down.
        let unbroken = readable.replacingOccurrences(of: "\n", with: "\u{A0}").replacingOccurrences(of: " ", with: "\u{A0}")
        let out = NSMutableAttributedString(attributedString: MathStyle.attributed(unbroken, base: base, color: color,
                                                                                  copy: ctx.link == nil ? formula.source : nil))
        // Spaces aren't the only break points: TextKit also breaks after a slash ("n(n+1)/" then "2." on the next line,
        // owner review 2026-10-31). A word joiner after every character forbids a break anywhere inside the formula.
        // It carries no kern, so the stacked limits' and italic correction's spacing stays where MathStyle put it.
        var at = out.length - 1
        while at > 0 {
            var attrs = out.attributes(at: at - 1, effectiveRange: nil)
            attrs[.kern] = nil
            out.insert(NSAttributedString(string: "\u{2060}", attributes: attrs), at: at)
            at -= 1
        }
        let full = NSRange(location: 0, length: out.length)
        out.addAttribute(.mathFormula, value: true, range: full)
        if let link = ctx.link { out.addAttribute(.chatLink, value: link, range: full) }
        if ctx.strike { out.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: full) }
        return out
    }

    /// A formula outside the subset: shown as its TeX source in the same card type fenced code uses (`appendCode`), so
    /// it behaves exactly like any other wide code block — horizontal scroll, not a clipped line (the n20 revisit
    /// screenshot showed "\end{aligned" cut off before this reused the card).
    private mutating func appendCodeText(_ body: String) {
        let para = MarkdownRenderer.paragraphStyle(lineHeight: style.codeLineHeight, font: style.code, spacingBefore: 0,
                                                   lineBreak: ChatRenderOptions.codeBlocksWrap ? .byWordWrapping : .byClipping)
        let text = NSMutableAttributedString(string: body, attributes: [
            .font: style.code, .foregroundColor: ChatPalette.codeText, .paragraphStyle: para,
            .baselineOffset: MarkdownRenderer.baselineOffset(lineHeight: style.codeLineHeight, font: style.code),
        ])
        let lines = body.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        out.append(.code(label: nil, code: body, text: text, lineCount: lines))
    }

    private mutating func appendTable(_ table: Markdown.Table) {
        let para = MarkdownRenderer.paragraphStyle(lineHeight: style.tableLineHeight, font: style.table, spacingBefore: 0, lineBreak: .byClipping)
        let offset = MarkdownRenderer.baselineOffset(lineHeight: style.tableLineHeight, font: style.table)
        func cell(_ c: Markdown.Table.Cell, header: Bool) -> NSAttributedString {
            var ctx = InlineContext()
            ctx.font = header ? style.tableBold : style.table
            if header { ctx.color = theme.secondary }
            let text = inlineText(c.children, ctx)
            // `<br>` and soft breaks are line breaks inside the cell; trim the ends.
            let trimmed = text.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return NSAttributedString() }
            // Literal, and never NSNotFound into attributedSubstring (it raises; this runs off the main thread).
            let range = (text.string as NSString).range(of: trimmed, options: .literal)
            let out = range.location == NSNotFound
                ? NSMutableAttributedString(string: trimmed, attributes: [.font: ctx.font ?? style.table,
                                                                          .foregroundColor: ctx.color ?? theme.text])
                : NSMutableAttributedString(attributedString: text.attributedSubstring(from: range))
            let full = NSRange(location: 0, length: out.length)
            out.addAttribute(.paragraphStyle, value: para, range: full)
            out.addAttribute(.baselineOffset, value: offset, range: full)
            return out
        }
        func plain(_ c: Markdown.Table.Cell) -> String {
            var s = ""
            for child in c.children { s += Self.plainInline(child) }
            return s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        }
        let headCells = Array(table.head.cells)
        let bodyRows = Array(table.body.rows).map { Array($0.cells) }
        let header = headCells.map { cell($0, header: true) }
        let rows = bodyRows.map { $0.map { cell($0, header: false) } }
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        guard columns > 0 else { return }
        let aligns: [NSTextAlignment] = (0..<columns).map { i in
            switch i < table.columnAlignments.count ? table.columnAlignments[i] : nil {
            case .right?: return .right
            case .center?: return .center
            default: return .natural
            }
        }
        // [transcript] The same text the Table sheet copies (tabs and line breaks inside a cell become spaces).
        // [transcript] F17: a cell's formula tokens back to their written TeX (Copy, the Table sheet's search text).
        let tsv = MathText.restore(TableText.text([headCells.map(plain)] + bodyRows.map { $0.map(plain) }), formulas)
        let flat = NSMutableAttributedString()
        for (i, line) in ([header] + rows).enumerated() {
            if i > 0 { flat.append(NSAttributedString(string: "\n")) }
            for (j, c) in line.enumerated() {
                if j > 0 { flat.append(NSAttributedString(string: "\t", attributes: [.font: style.table])) }
                flat.append(c)
            }
        }
        var made = MarkdownTable(header: header, rows: rows, alignments: aligns, plain: tsv, flat: flat)
        made.numeric = TableData.numericColumns(bodyRows.map { $0.map(plain) }, columns: columns)
        if case .text(let before)? = out.last, before.length > 0 {
            // A heading's font is larger than the body's.
            let font = before.attribute(.font, at: before.length - 1, effectiveRange: nil) as? UIFont
            made.caption = TableData.caption(before: before.string, lastLineIsHeading: (font?.pointSize ?? 0) > style.body.pointSize + 0.5)
        }
        out.append(.table(made))
    }

    // MARK: Inlines

    func inlineText<S: Sequence>(_ nodes: S, _ ctx: InlineContext) -> NSMutableAttributedString where S.Element == Markup {
        let out = NSMutableAttributedString()
        for node in nodes { inline(node, ctx, into: out) }
        if filePaths, ctx.link == nil { linkBarePaths(out) }
        return out
    }

    /// A path written out in the words, not in backticks, opens the file too (`FileLinks.bare`). Run over the whole
    /// paragraph: the parser can split one path into several text runs ("_" and "~" are markup characters). Words
    /// already in a link or a code box keep what they had.
    private func linkBarePaths(_ text: NSMutableAttributedString) {
        for (range, path) in FileLinks.bare(in: text.string) {
            var taken = false
            text.enumerateAttributes(in: range) { attrs, _, stop in
                // [transcript] F17: a formula's rendered text is never a path, even when it reads "(a+b)/c".
                if attrs[.chatLink] != nil || attrs[.inlineCodeBox] != nil || attrs[.mathFormula] != nil { taken = true; stop.pointee = true }
            }
            guard !taken, let url = FileLinks.url(path) else { continue }
            text.addAttribute(.chatLink, value: url, range: range)
            text.addAttribute(.foregroundColor, value: theme.link, range: range)
            if theme.underlineLinks { text.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
        }
    }

    private func inline(_ node: Markup, _ ctx: InlineContext, into out: NSMutableAttributedString) {
        switch node {
        case let t as Markdown.Text where !formulas.isEmpty && (t.string.contains(MathText.inlineOpen) || t.string.contains(MathText.blockOpen)):
            // [transcript] F17: a formula inside a sentence.
            for piece in MathText.pieces(t.string) {
                switch piece {
                case .text(let words):
                    if ctx.link == nil { appendAutolinked(words, ctx, into: out) } else { out.append(styled(words, ctx)) }
                case .formula(let i) where i < formulas.count:
                    out.append(inlineFormula(formulas[i], ctx))
                case .formula: break
                }
            }
        case let t as Markdown.Text:
            if ctx.link == nil {
                appendAutolinked(t.string, ctx, into: out)
            } else {
                out.append(styled(t.string, ctx))
            }
        case is SoftBreak, is LineBreak:
            out.append(styled("\u{2028}", ctx))
        case let c as InlineCode:
            var linked = ctx
            if filePaths, ctx.link == nil, let path = FileLinks.path(inCode: c.code) {
                linked.link = FileLinks.url(path)   // a file the bot names: tapping opens it in Files
            }
            var attrs = attributes(linked)
            attrs[.font] = style.inlineCode
            attrs[.backgroundColor] = theme.inlineCodeFill
            attrs[.inlineCodeBox] = true
            // Code reads left to right even inside a right-to-left sentence (spec 03 §9.5 "forced LTR").
            attrs[.writingDirection] = [NSWritingDirection.leftToRight.rawValue | NSWritingDirectionFormatType.embedding.rawValue]
            if linked.link == nil { attrs[.chatCopy] = c.code }
            // Narrow no-break spaces pad the box without letting a line break between the padding and the code.
            out.append(NSAttributedString(string: "\u{202F}" + InlineCodeText.display(c.code) + "\u{202F}", attributes: attrs))
        case let e as Emphasis:
            var c = ctx; c.italic = true
            for child in e.children { inline(child, c, into: out) }
        case let s as Strong:
            var c = ctx; c.bold = true
            for child in s.children { inline(child, c, into: out) }
        case let s as Strikethrough:
            var c = ctx; c.strike = true
            for child in s.children { inline(child, c, into: out) }
        case let l as Markdown.Link:
            var c = ctx
            c.dest = l.destination   // [morepages]
            if let dest = l.destination, let ref = MarkdownMedia.ref(destination: dest, title: l.plainText, image: false) {
                // [attachments] an inline media or file link: a glyph, then the link (taps open the viewer / preview)
                c.link = MarkdownMedia.linkURL(ref)
                out.append(MarkdownMedia.glyph(ref, font: attributes(ctx)[.font] as? UIFont ?? style.body, color: theme.link))
            } else if let dest = l.destination, let url = URL(string: dest), url.scheme != nil || dest.hasPrefix("#") {
                c.link = url
            }
            let before = out.length
            if let dest = l.destination, dest.hasPrefix("#media:"), let ref = MarkdownMedia.ref(destination: dest, title: l.plainText, image: false) {
                // [attachments] the glyph says what it is: "File: data.csv" reads "data.csv"
                out.append(styled(MarkdownMedia.inlineTitle(l.plainText, ref: ref), c))
            } else {
                for child in l.children { inline(child, c, into: out) }
            }
            if out.length == before, let dest = l.destination { out.append(styled(dest, c)) }
        case let i as Markdown.Image:
            var c = ctx
            let alt = i.plainText.isEmpty ? "Image" : i.plainText
            if let src = i.source, let ref = MarkdownMedia.ref(destination: src, title: alt, image: true) {
                // [attachments] an image inside a sentence: a photo glyph and its alt text as a link to the viewer
                c.link = MarkdownMedia.linkURL(ref)
                out.append(MarkdownMedia.glyph(ref, font: attributes(ctx)[.font] as? UIFont ?? style.body, color: theme.link))
                out.append(styled(alt, c))
            } else {
                if let src = i.source, let url = URL(string: src), url.scheme?.hasPrefix("http") == true { c.link = url }
                out.append(styled("🖼 " + alt, c))
            }
        case let h as InlineHTML:
            if h.rawHTML.range(of: #"^<br\s*/?>$"#, options: [.regularExpression, .caseInsensitive]) != nil {
                out.append(styled("\u{2028}", ctx))
            } else {
                out.append(styled(h.rawHTML, ctx))
            }
        default:
            if node.childCount > 0 {
                for child in node.children { inline(child, ctx, into: out) }
            } else if let inlineNode = node as? InlineMarkup {
                out.append(styled(inlineNode.plainText, ctx))
            }
        }
    }

    private func appendAutolinked(_ text: String, _ ctx: InlineContext, into out: NSMutableAttributedString) {
        guard text.contains("http") else { out.append(styled(text, ctx)); return }
        let ns = text as NSString
        var cursor = 0
        for m in MarkdownRenderer.bareURL.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            // A closing bracket the address didn't open is the sentence's ("(see https://site.com/page)").
            let length = MarkdownRenderer.bareURLEnd(ns.substring(with: m.range) as NSString)
            guard length > 0 else { continue }
            if m.range.location > cursor {
                out.append(styled(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)), ctx))
            }
            let s = ns.substring(with: NSRange(location: m.range.location, length: length))
            var c = ctx
            c.link = URL(string: s)
            out.append(styled(s, c))
            cursor = m.range.location + length
        }
        if cursor < ns.length { out.append(styled(ns.substring(from: cursor), ctx)) }
    }

    func styled(_ s: String, _ ctx: InlineContext) -> NSAttributedString {
        NSAttributedString(string: s, attributes: attributes(ctx))
    }

    func attributes(_ ctx: InlineContext) -> [NSAttributedString.Key: Any] {
        var font = ctx.font ?? style.body
        if ctx.font == nil {
            switch (ctx.bold, ctx.italic) {
            case (true, true): font = style.bodyBoldItalic
            case (true, false): font = style.bodyBold
            case (false, true): font = style.bodyItalic
            default: break
            }
        } else {
            // A set font (headings, table cells) still takes bold and italic from the markup.
            var traits = font.fontDescriptor.symbolicTraits
            let weight = (font.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any])?[.weight] as? CGFloat ?? 0
            if ctx.bold && weight < UIFont.Weight.semibold.rawValue { traits.insert(.traitBold) }
            if ctx.italic { traits.insert(.traitItalic) }
            if traits != font.fontDescriptor.symbolicTraits, let d = font.fontDescriptor.withSymbolicTraits(traits) {
                font = UIFont(descriptor: d, size: font.pointSize)
            }
        }
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ctx.color ?? theme.text]
        if ctx.strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let dest = ctx.dest { attrs[.markdownDestination] = dest }   // [morepages]
        if let link = ctx.link {
            attrs[.chatLink] = link
            attrs[.foregroundColor] = theme.link
            if theme.underlineLinks { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        }
        return attrs
    }

    private static func plainInline(_ node: Markup) -> String {
        switch node {
        case let t as Markdown.Text: return t.string
        case let c as InlineCode: return c.code
        case is SoftBreak, is LineBreak: return " "
        case let h as InlineHTML:
            return h.rawHTML.range(of: #"^<br\s*/?>$"#, options: [.regularExpression, .caseInsensitive]) != nil ? " " : h.rawHTML
        default: return node.children.map(plainInline).joined()
        }
    }
}

/// Switches for presentation choices the spec leaves open.
nonisolated enum ChatRenderOptions {
    /// Code fences never wrap: long lines scroll sideways inside the card (spec 06 §2.6, which wins on look and feel
    /// over the M1 brief's wrapping).
    static let codeBlocksWrap = false
}

// MARK: - Preprocessing (spec 03 §9.2, the M1 part)

nonisolated enum MarkdownPreprocess {
    // swiftlint:disable force_try
    private static let previewMarker = try! NSRegularExpression(pattern: #"\[Preview:[^\]\n]*\]\(#preview[^)\n]*\)"#)
    // swiftlint:enable force_try

    static func run(_ text: String, streaming: Bool = false) -> String {
        // Reasoning blocks go from the prose; a code block that shows such a tag keeps it (`ReasoningTags`).
        let source = escapeURLMarkup(ReasoningTags.strip(text.replacingOccurrences(of: "\r\n", with: "\n"), streaming: streaming))
        // Prose-only transforms: leave fenced code untouched. [transcript] F17: display math (`$$`/`\[`) is no longer
        // turned into a code block here — `MathText.extract` takes every formula out after this pass, and the
        // renderer draws it (or its source, when it can't).
        guard source.contains("MEDIA:") || source.contains("![") || source.contains("[Preview:")
                || source.contains("::preview{") || mayHoldBarePath(source) else {
            return source
        }
        var out: [String] = []
        var fence: String?
        // Pictures named inside a list item, quote or table row: they follow once that block has ended.
        var held: [String] = []
        func release() {
            guard !held.isEmpty else { return }
            if let last = out.last, !last.trimmingCharacters(in: .whitespaces).isEmpty { out.append("") }
            out.append(held.map(MediaTags.link).joined(separator: " "))
            out.append("")
            held = []
        }
        for raw in source.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // A new unindented paragraph after a blank line: the block before it is over.
            if !held.isEmpty, fence == nil, !line.isEmpty, raw.first?.isWhitespace == false, out.last?.isEmpty == true,
               !MarkdownPreprocess.continuesBlock(line) {
                release()
            }
            if let f = fence {
                out.append(raw)
                if line.hasPrefix(f) && line.trimmingCharacters(in: CharacterSet(charactersIn: String(f.first!))).isEmpty { fence = nil }
                continue
            }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                if raw.first?.isWhitespace == false { release() }
                fence = String(line.prefix(while: { $0 == line.first }))
                out.append(raw)
                continue
            }
            var l = raw
            if l.contains("[Preview:") {
                l = previewMarker.stringByReplacingMatches(in: l, range: NSRange(l.startIndex..., in: l), withTemplate: "")
            }
            // [attachments] `MEDIA:` tags (web parity), then bare picture paths (spec §7.5, DECISION A16)
            let tags = MediaTags.renderTags(l)
            l = tags.text
            var mediaLine = tags.mediaOnly
            var follow: [String] = []
            if !mediaLine {
                let bare = MediaTags.renderBarePaths(l)
                l = bare.text
                mediaLine = bare.mediaOnly
                if bare.inBlock {
                    held += bare.images.filter { !held.contains($0) }
                } else {
                    follow = bare.images
                }
            }
            if mediaLine || MarkdownMedia.isImageOnlyLine(l) {
                // [attachments] a line of media only is its own paragraph (an image block, spec §7.5)
                if let last = out.last, !last.trimmingCharacters(in: .whitespaces).isEmpty { out.append("") }
                out.append(l)
                out.append("")
                continue
            }
            out.append(l)
            if !follow.isEmpty {
                // A picture named inside a sentence follows it as its own paragraph.
                out.append("")
                out.append(follow.map(MediaTags.link).joined(separator: " "))
                out.append("")
            }
        }
        release()
        return out.joined(separator: "\n")
    }

    /// A bare web address keeps its `_` and `~`: they are escaped before parsing, so "https://x.com/_draft_/~~a~~"
    /// never turns part of the address into italics or strikethrough (which split the link, and the tap opened a page
    /// cut short). The parser joins the escaped characters back into one text run, which the autolinker links whole.
    /// Prose only: code fences, indented code, inline code spans, `<…>` autolinks and HTML attributes stay as written.
    static func escapeURLMarkup(_ source: String) -> String {
        guard source.contains("http"), source.contains("_") || source.contains("~") else { return source }
        var fence: String?
        var changed = false
        let lines = source.components(separatedBy: "\n").map { raw -> String in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let f = fence {
                if line.hasPrefix(f) && line.trimmingCharacters(in: CharacterSet(charactersIn: String(f.first!))).isEmpty { fence = nil }
                return raw
            }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                fence = String(line.prefix(while: { $0 == line.first }))
                return raw
            }
            guard raw.contains("http"), raw.contains("_") || raw.contains("~"), !raw.hasPrefix("    "), !raw.hasPrefix("\t") else { return raw }
            let escaped = escapeURLs(inLine: raw)
            if escaped != raw { changed = true }
            return escaped
        }
        return changed ? lines.joined(separator: "\n") : source
    }

    private static func escapeURLs(inLine line: String) -> String {
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        let code = inlineCodeSpan.matches(in: line, range: full).map(\.range)
        let out = NSMutableString(string: line)
        for m in MarkdownRenderer.bareURL.matches(in: line, range: full).reversed() {
            if code.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) { continue }
            if m.range.location > 0, "<\"'=\\".utf16.contains(ns.character(at: m.range.location - 1)) { continue }
            let url = ns.substring(with: m.range) as NSString
            let end = MarkdownRenderer.bareURLEnd(url)
            var escaped = ""
            var previous: Character?
            for ch in url.substring(to: end) {
                if (ch == "_" || ch == "~") && previous != "\\" { escaped.append("\\") }
                escaped.append(ch)
                previous = ch
            }
            out.replaceCharacters(in: NSRange(location: m.range.location, length: end), with: escaped)
        }
        return out as String
    }

    // swiftlint:disable:next force_try
    private static let inlineCodeSpan = try! NSRegularExpression(pattern: "(`+)[^`\\n]*?\\1")

    /// A line that keeps a list, quote or table going: another item, quote line or row.
    private static func continuesBlock(_ line: String) -> Bool {
        line.hasPrefix(">") || line.hasPrefix("|") || line.range(of: #"^(?:[-*+]|\d+[.)])\s"#, options: .regularExpression) != nil
    }

    private static func mayHoldBarePath(_ source: String) -> Bool {
        (source.contains("/") || source.contains("\\"))
            && source.range(of: #"\.(?:png|jpe?g|gif|webp|bmp|heic|heif|tiff?)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// [attachments] the kind table of docs/spec/1x-attachments.md §7.5 (`.svg` is a file).
    static func mediaKind(_ path: String) -> String {
        switch MediaKinds.refKind(ofName: path) {
        case .image: return "Image"
        case .video: return "Video"
        case .audio: return "Audio"
        case .file: return "File"
        }
    }
}

/// Your own message's markdown (docs/spec/03-chat-history.md §9.5, DECISION 2026-10-26): inline styles (bold, italic,
/// strikethrough, inline code, links) and fenced code blocks render; every line-level construct (headings, lists,
/// quotes, tables, rules, HTML blocks, indented code, link definitions) stays as you typed it. The web draws code spans
/// and fences in your bubble (`V:components/assistant-ui/thread/user-message-text.tsx:8-12,122-140`); tester
/// a tester asked for inline markdown and worried it might look "too weird", so the lines keep their shape.
nonisolated enum UserMarkdown {
    // swiftlint:disable force_try
    private static let orderedMarker = try! NSRegularExpression(pattern: #"^(\d{1,9})([.)])(?=\s|$)"#)
    private static let tableDelimiter = try! NSRegularExpression(pattern: #"^\|?\s*:?-+:?\s*(?:\|\s*:?-+:?\s*)+\|?\s*$"#)
    private static let rule = try! NSRegularExpression(pattern: #"^(?:[-*_=]\s*)+$"#)
    private static let linkDefinition = try! NSRegularExpression(pattern: #"^\[[^\]]+\]:"#)
    // swiftlint:enable force_try

    /// Characters that make a message worth parsing; anything else draws exactly as plain text.
    static func hasMarkup(_ text: String) -> Bool {
        text.contains(where: { "*_~`[".contains($0) }) || text.contains("http") || text.hasPrefix(">")
    }

    /// Your message's words for VoiceOver, as drawn: inline markup gone, the line markers you typed kept.
    static func spoken(_ text: String) -> String {
        let escaped = SpokenMarkdown.plain(escapeBlocks(text)).replacingOccurrences(of: "\u{00A0}", with: " ")
        return escaped.replacingOccurrences(of: #"\\([#>|:<\-+*=_.)\[])"#, with: "$1", options: .regularExpression)
    }

    /// The text with every line-level marker escaped, so only inline markdown and fences are left to parse. Leading
    /// spaces become no-break spaces (your indentation stays and never turns into a code block). The one exception is
    /// a quote that opens the message (Swipe to Reply's quote of the bot's words): it stays a quote.
    static func escapeBlocks(_ text: String) -> String {
        var out: [String] = []
        var fence: String?
        var leadingQuote = true
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if leadingQuote, raw.hasPrefix(">") {
                out.append("> " + escapeLine(String(raw.dropFirst()).trimmingCharacters(in: .whitespaces)))
                continue
            }
            leadingQuote = false
            if let f = fence {
                out.append(raw)
                if trimmed.hasPrefix(f) && trimmed.trimmingCharacters(in: CharacterSet(charactersIn: String(f.first!))).isEmpty { fence = nil }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(while: { $0 == trimmed.first }))
                out.append(trimmed)
                continue
            }
            let indent = String(raw.prefix(while: { $0 == " " || $0 == "\t" }))
            out.append(String(repeating: "\u{00A0}", count: indent.replacingOccurrences(of: "\t", with: "    ").count) + escapeLine(trimmed))
        }
        return out.joined(separator: "\n")
    }

    private static func escapeLine(_ line: String) -> String {
        guard let first = line.first else { return line }
        let range = NSRange(location: 0, length: (line as NSString).length)
        if rule.firstMatch(in: line, range: range) != nil || tableDelimiter.firstMatch(in: line, range: range) != nil
            || linkDefinition.firstMatch(in: line, range: range) != nil || "#>|:<".contains(first) {
            return "\\" + line
        }
        if "-+*".contains(first), line.dropFirst().first.map({ $0 == " " || $0 == "\t" }) ?? true { return "\\" + line }
        if first.isNumber, let m = orderedMarker.firstMatch(in: line, range: range) {
            let ns = line as NSString
            return ns.substring(with: m.range(at: 1)) + "\\" + ns.substring(from: m.range(at: 2).location)
        }
        return line
    }
}
