// Mac polish audit 2026-11-06, batch 6 (replies and group chats): the rules behind each fix, one test per item.

import Testing
import UIKit
@testable import HermesHQNative

private func theme(look: Bool, scale: Int) -> ThemeSet {
    ThemeResolver.resolve(ThemeState(skinID: "ios", desktopLook: look, highContrast: false, uiScalePercent: scale))
}

@MainActor @Suite struct MacPolish6Tests {
    // #71: a size read back from a font HQFont already made carries UI Scale; it is not scaled a second time.
    @Test(arguments: [false, true]) func scaledSizesAreNotScaledTwice(look: Bool) {
        ThemeTable.$testSet.withValue(theme(look: look, scale: 150)) {
            let style = ChatStyle.make(category: .large)
            #expect(TextLayout.senderNameFont(style).pointSize == style.notice.pointSize,
                    "a group chat's name line is the notice's size, not bigger than the message under it")
            let body = HQFont.preferred(.body, compatibleWith: UITraitCollection.current).pointSize
            #expect(ModelPanelView.font(.body, .semibold).pointSize == body, "the model panel's text is the app's size")
        }
    }

    // #24: a chat painted from its saved copy offers earlier messages only when it knows of some.
    @Test func aShortSavedChatOffersNothingEarlierBeforeTheGatewayAnswers() throws {
        func rows(_ count: Int) -> [ChatMessage] {
            (1...count).map { i in
                ChatMessage(id: "row-\(i)", role: i % 2 == 1 ? .user : .assistant, parts: [.text("message \(i)")],
                            timestamp: Date(timeIntervalSince1970: Double(i)), rowId: i)
            }
        }
        let h = try ChatHarness()
        let s = h.make()
        s.applyCachedPaint(TranscriptEntry(messages: rows(4), meta: [:], savedAt: Date()))
        #expect(s.messages.count == 4)
        #expect(!s.hasOlder, "four saved messages, all shown: no 'Show earlier messages' until the first page says so")
        let long = h.make()
        long.applyCachedPaint(TranscriptEntry(messages: rows(40), meta: [:], savedAt: Date()))
        #expect(long.messages.count < 40)
        #expect(long.hasOlder, "the window left saved messages out: there is something earlier")
        let shortened = h.make()
        shortened.applyCachedPaint(TranscriptEntry(messages: rows(2), meta: [:], savedAt: Date(), partial: true))
        #expect(shortened.hasOlder, "a shortened offline copy")
    }

    // #25: a /btw card keeps the answer's bold and code, and sets the question apart from it.
    @Test func aByTheWayCardKeepsItsFormattingAndSetsTheQuestionApart() throws {
        let answer = SideTaskRow.message(kind: .btw, taskId: "btw_fmt001", asked: "which port does the dev server use?",
                                         text: "It listens on **port 8080**; `src/main.py` sets it.", at: Date())
        let id = "\(answer.id)|bg"
        let rows = ChatRowBuilder.build(.init(messages: [answer], isRunning: false, botName: "Hermes", expanded: [id]))
        let row = try #require(rows.first { $0.id == id })
        let style = ChatStyle.make(category: .large)
        guard case .tool(let t) = TextLayout.layout(row, width: 390, style: style, keep: false).content else {
            Issue.record("expected a tool layout"); return
        }
        let text = try #require(t.thoughtText?.text)
        let string = text.string as NSString
        #expect(string.hasPrefix("which port does the dev server use?"), "the question leads")
        #expect(!text.string.contains("**") && !text.string.contains("`"), "no Markdown marks shown")
        let question = text.attributes(at: 0, effectiveRange: nil)
        let bold = text.attributes(at: string.range(of: "port 8080").location, effectiveRange: nil)
        let code = text.attributes(at: string.range(of: "src/main.py").location, effectiveRange: nil)
        let plain = text.attributes(at: string.range(of: "It listens").location, effectiveRange: nil)
        #expect((question[.foregroundColor] as? UIColor) == ChatPalette.label2, "the question in the secondary ink")
        #expect((plain[.foregroundColor] as? UIColor) != ChatPalette.label2, "the answer in the reply's ink")
        #expect((bold[.font] as? UIFont)?.fontDescriptor.symbolicTraits.contains(.traitBold) == true, "bold stays bold")
        #expect((code[.font] as? UIFont)?.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) == true, "code stays code")
    }

    // #72: a sum's two limits stack at one x. Since 2026-11-09 a sum is typeset (`MathTypeset`): the maths font
    // stacks its limits, and the whole formula is one attachment in the sentence.
    @Test func aSumsLimitsStackAtOneX() throws {
        let style = ChatStyle.make(category: .large)
        var rendered: NSAttributedString?
        for block in MarkdownRenderer.render("The sum is $\\sum_{i=1}^{n} k$ here.", style: style).blocks {
            if case .text(let t) = block { rendered = t }
        }
        let text = try #require(rendered)
        var formulas: [MathAttachment] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let set = value as? MathAttachment { formulas.append(set) }
        }
        let sum = try #require(formulas.first)
        #expect(formulas.count == 1)
        #expect(sum.latex.contains("\\sum"))
        #expect(!text.string.contains("∑"), "not the old stand-in letters")
        #expect(sum.bounds.width < style.body.pointSize * 4, "limits stacked over the sign, not trailing after it")
    }

    private func reply(_ markdown: String, width: CGFloat) throws -> BubbleLayout {
        var bubble = BubbleRow(mine: false, text: markdown, markdown: true, partIndex: 0, joinsAbove: false, joinsBelow: false,
                               tail: true, time: nil, pending: false, streaming: false, speaker: "Hermes", expanded: true)
        bubble.senderInset = false
        let row = ChatRow(id: "r|b0", messageId: "r", scope: "", fingerprint: markdown.hashValue, kind: .bubble(bubble), gapAbove: 0, variant: 0)
        guard case .bubble(let b) = TextLayout.make(row, width: width, style: ChatStyle.make(category: .large)).content else {
            throw CancellationError()
        }
        return b
    }

    private func codeCards(_ b: BubbleLayout) -> [PlacedBlock] {
        b.blocks.filter { if case .code = $0.block { return true } else { return false } }
    }

    private let longCommand = "hermes up --profile default --gateway https://gateway.example.invalid:8642/api/v1 --token-file "
        + "~/.config/hermes/token --retries 5 --log-level debug"

    // #73: an unlabelled one-line command that scrolls sideways keeps the compact card: no empty band over its line.
    @Test func aLongOneLineCommandHasNoEmptyBandOverIt() throws {
        let card = try #require(codeCards(try reply("Run it:\n\n```\n\(longCommand)\n```", width: 390)).first)
        #expect(card.contentWidth > card.textFrame.width, "the line scrolls sideways")
        #expect(card.textFrame.minY == 0, "no strip over the line (it held only the copy button)")
        #expect(card.frame.height < ChatMetrics.codeStrip + ChatMetrics.codeCompactMinHeight, "one band, not a strip and a band")
        #expect(card.textFrame.maxX <= card.frame.width - ChatMetrics.codeCompactTrailing + 0.5, "the line stops short of the copy button")
    }

    // #76: in a reply whose wide table widened its cards, a code card's text area reaches its card's edge too.
    @Test func aCodeCardsTextAreaGrowsWithItsCard() throws {
        let header = "| " + (1...14).map { "Column \($0)" }.joined(separator: " | ") + " |"
        let rule = "|" + String(repeating: "---|", count: 14)
        let cells = "| " + (1...14).map { "value \($0)" }.joined(separator: " | ") + " |"
        let markdown = "\(header)\n\(rule)\n\(cells)\n\n```sh\n\(longCommand) \(longCommand)\n```"
        let b = try reply(markdown, width: 1_400)
        let card = try #require(codeCards(b).first)
        #expect(card.contentWidth > card.textFrame.width, "the line still scrolls sideways")
        #expect(abs(card.textFrame.maxX - (card.frame.width - ChatMetrics.codePadH)) < 0.5,
                "the text area ends at the card's own padding: \(card.textFrame.maxX) in a card \(card.frame.width) wide")
    }

    #if targetEnvironment(macCatalyst)
    // #74: in the Desktop Look your own words select in the reply's highlight, not a grey block.
    @Test func yourWordsSelectInTheRepliesHighlightInTheDesktopLook() {
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        func drawn(mine: Bool, look: Bool) -> UIColor { ChatBubbleCell.selectionColor(mine: mine, desktopLook: look).resolvedColor(with: dark) }
        #expect(drawn(mine: true, look: true) == drawn(mine: false, look: true))
        #expect(drawn(mine: true, look: false) != drawn(mine: false, look: false), "the iOS look's tinted bubble keeps white")
    }
    #endif

    // #75: a table whose header has arrived but no row yet says no "0 rows" and offers no Expand.
    @Test func aTableWithNoRowsYetOffersNoCountAndNoExpand() {
        let footer = TableFooterControl(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        func shown() -> [String] {
            footer.layoutIfNeeded()
            return footer.subviews.compactMap { $0 as? UILabel }.filter { !$0.isHidden }.compactMap(\.text).filter { !$0.isEmpty }
        }
        footer.configure(rows: 0, columns: 3, footerHeight: 36)
        #expect(shown().isEmpty, "\(shown())")
        #expect(!footer.isEnabled && !footer.isAccessibilityElement, "nothing to expand")
        footer.configure(rows: 2, columns: 3, footerHeight: 36)
        #expect(shown().contains("Expand") && shown().contains { $0.hasPrefix("2 rows") }, "\(shown())")
        #expect(footer.isEnabled && footer.isAccessibilityElement)
    }

    // #16: a group chat's @ list takes the message field's list keys, as a bot chat's drawer does.
    @Test func theGroupChatsMentionListTakesTheListKeys() {
        let list = RoomMentionList()
        var picked: [String] = []
        list.onPick = { picked.append($0) }
        _ = list.set([RoomMentionList.Row(tag: "everyone", name: "@everyone", detail: "Every bot", sender: nil),
                      RoomMentionList.Row(tag: "finn", name: "Finn", detail: "@finn", sender: nil),
                      RoomMentionList.Row(tag: "fiona", name: "Fiona", detail: "@fiona", sender: nil)])
        #expect(list.marked == nil && !list.pickMarked(), "nothing marked: Return sends as ever")
        list.key(.down)
        list.key(.down)
        #expect(list.marked == 1)
        list.key(.down)
        list.key(.down)
        #expect(list.marked == 2, "↓ stops at the last row")
        #expect(list.pickMarked() && picked == ["fiona"], "Return picks the marked row")
        list.key(.up)
        list.key(.up)
        list.key(.up)
        #expect(list.marked == nil, "↑ from the first row marks none")
        list.key(.tab)
        #expect(picked == ["fiona", "everyone"], "Tab with nothing marked picks the first")
        _ = list.set([RoomMentionList.Row(tag: "finn", name: "Finn", detail: "@finn", sender: nil)])
        #expect(list.marked == nil, "typing starts over")
    }
}
